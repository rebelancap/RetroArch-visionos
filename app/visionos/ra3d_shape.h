/* ra3d_shape.h — the 3dSen shape layer, in C.
 *
 * A single-header (stb-style) port of our Python prototype (shape assembly
 * and geometry emit): it parses a `.3dn` profile once at content load,
 * then per frame turns Mesen's RA3D scene stream (overlay 0059/0060) into the
 * `ra3d-geo/1` instance array the Metal consumer draws.
 *
 *   #define RA3D_SHAPE_IMPLEMENTATION
 *   #include "ra3d_shape.h"
 *
 * Header-only ON PURPOSE: adding a .c to the visionOS build means
 * editing `project.pbxproj`, and the only patch that does so — overlay 0013 —
 * is hand-written, so a second patch anchoring inside its hunks would make it
 * neither forward- nor reverse-appliable (the rule apply-overlay.sh enforces).
 * One `#define` in RAVisionLayers.m costs nothing and keeps 0013 untouched.
 * The same header is compiled by a desktop CLI that gated it against the
 * Python prototype, so both sides are literally one algorithm.
 *
 * Pure C99. No Foundation, no Metal, no protobuf runtime, no Lua, no malloc in
 * the per-frame path once the buffers have grown. Everything the profile costs
 * is paid at load.
 *
 * -------------------------------------------------------------------------
 * WHAT THE ALGORITHM IS
 *
 * A `.3dn` Pattern is a WxH grid of `Tile2D` (raw 16 CHR bytes + a flip pair,
 * stored as RotateLeft(v,26) ^ 0x000708FACD884A5A in the file).
 * An INSTANCE is an anchor (ax, ay) in SCREEN PIXELS where every constrained
 * cell has a scene tile of the right identity at (ax + 8gx, ay + 8gy). Pixel
 * space rather than a tile grid, so fine-X scroll and OAM coordinates need no
 * special case. Background and sprite cells match as separate layer classes.
 * Candidates are scored (more cells > bigger grid > tighter constraint > lower
 * id) and accepted greedily, so the output is a PARTITION — nothing is
 * extruded twice. A constrained cell is exempt when the frame cannot show it
 * (off-screen, or a different scroll region), which is what rescues objects
 * scrolling off an edge.
 *
 * Then each instance takes its pattern's first `Pattern3D`: one of six
 * `Geo3DType` primitives, extruded by SizeZ, placed by Offset/Scale/Rot/Pivot,
 * tinted by Alpha, pushed onto its ZLayer. Cells no pattern claimed become 1x1
 * fallback slabs so an unprofiled corner degrades to today's flat-plane look
 * instead of to a hole.
 *
 * WORLD SPACE is NES pixels: +X right, +Y DOWN, +Z toward the viewer, origin at
 * the picture's top-left. +Y down is why `look_at` here must use
 * `s = cross(up, f)`; the textbook `cross(f, up)` silently mirrors the scene
 * (it cost one render in Python and would cost one in Metal).
 */
#ifndef RA3D_SHAPE_H
#define RA3D_SHAPE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- the input
 * Byte-identical to `Ra3dSceneTile` / `Ra3dScene` in the core's Core/PPU.h.
 * Declared again here rather than included, because the shell cannot see the
 * core's C++ headers — it reaches the core through dlsym across a C ABI. */

typedef struct
{
   int16_t  X;          /* screen x of the cell's top-left corner; negative    */
   int16_t  Y;          /* when the cell is clipped off the left or top edge   */
   uint16_t Chr;        /* index into this frame's CHR atlas                   */
   uint8_t  Layer;      /* 0 background, 1 sprite behind BG, 2 sprite in front */
   uint8_t  Palette;    /* 0-3 background palette, 4-7 sprite palette          */
   uint8_t  Flags;      /* bit0 flip X, bit1 flip Y, bit2 lower half of 8x16   */
   uint8_t  Oam;        /* OAM index for a sprite, 0xFF for a background tile  */
   int16_t  ScrollX;
   int16_t  ScrollY;
   uint16_t Nametable;
   int32_t  ChrAddr;
} Ra3dSceneTile;

typedef struct
{
   uint32_t             FrameNumber;
   uint16_t             TileCount;
   uint16_t             AtlasCount;
   const Ra3dSceneTile *Tiles;
   const uint8_t       *Atlas;        /* AtlasCount * 16 raw CHR bytes */
   const uint8_t       *PaletteRam;   /* 32 bytes */
   const uint32_t      *RgbPalette;   /* 512 entries, ARGB */
} Ra3dScene;

/* --------------------------------------------------------------- the output */

/* One 8x8 cell of an instance's front face. The array is DENSE (w*h entries
 * per instance, row-major) so the fragment shader can index it directly from
 * the interpolated uv; `chr == RA3D_CELL_EMPTY` means "nothing here, stay
 * transparent". (`ra3d-geo/1`'s JSON is sparse; dense is the same information
 * laid out for a GPU, and is the one deviation from the schema —.) */
#define RA3D_CELL_EMPTY 0xFFFFu

typedef struct
{
   uint8_t  gx, gy;
   uint8_t  pal;        /* 0-7 palette group */
   uint8_t  flip;       /* bit0 flipX, bit1 flipY */
   uint16_t chr;        /* atlas index, or RA3D_CELL_EMPTY */
   uint16_t pad;        /* with a Direct-colour instance, 1 +
                         * the texture tile this cell draws; else 0 */
} Ra3dGeoCell;          /* 8 bytes */

/* 112 bytes, 16-byte aligned: uploaded straight into a Metal buffer and read
 * per-instance by the vertex shader. Widened from the ra3d-geo/1 docstring's
 * 64-byte sketch — `cell_count` needs 16 bits (a 22x11 title logo is 242
 * cells) and pivot/pattern earn their place (pivot is a real placement input,
 * pattern is what makes a wrong instance identifiable in a screenshot). */
typedef struct
{
   float    pos[3];     float alpha;
   float    size[3];                  /* w, h, depth — world px */
   uint32_t pal_override;             /* 0 none, else palette group + 1
                                       * (Lua shape.Palette, 0-15; 16 = the
                                       * Backdrop's own colour) */
   float    scale[3];
   uint32_t dtex;                     /* 0 none, else 1 + the first
                                       * texel of the Pattern3D's Direct-colour
                                       * texture in Ra3dGeoFrame.dtex; its width
                                       * is size[0] (only bound when the box is
                                       * exactly the texture's size) */
   float    rot[3];                   /* Euler degrees */
   uint32_t dtex_gw;                  /* with dtex, the texture's
                                       * width in tiles; the cells then carry
                                       * 1 + their texture tile in `pad` */
   float    offset[3];  float pad3;
   float    pivot[3];   float pad4;   /* fraction of size */
   uint32_t cell_offset;              /* index into Ra3dGeoFrame.cells */
   uint16_t cell_count;               /* == grid_w * grid_h */
   uint8_t  geo;                      /* Geo3DType 0-5 */
   uint8_t  zlayer;                   /* 0 UNIDENTIFIED, 1 UI, 2-5 L1-L4 */
   int32_t  pattern;                  /* .3dn pattern id, -1 for a fallback  */
   uint32_t flags;                    /* bit0 = fallback, bit1 = sprite class */
} Ra3dGeoInstance;

/* 3dSen's frame height is 248 px (31 rows), and its frame is +Y up with
 * world Y = 248 - nesY (BottomLeft/BL/GetPos, Frame.AddNewShape as scripts
 * see them): BottomLeft.y = 248 - pEnd.y, BL.y = 247 - pEnd.y,
 * TR.y = 247 - pStart.y. Using 240 instead
 * puts every script-visible position 8 px low: SMB's second HUD row read
 * BottomLeft.y 210 against `ui`'s `> 216` and never became UI. */
#define RA3D_UNITY_H 248
#define RA3D_NO_SHAPE 0xFFFFFFFFu
#define RA3D_INST_FALLBACK 1u
#define RA3D_INST_SPRITE   2u
/* the Pattern3D fill flags the voxel mesher needs (ra3d_vox.h). */
#define RA3D_INST_ANTISHADOW  4u    /* Pattern3D field 3 */
#define RA3D_INST_FLIP        8u    /* field 4 — half-cylinder anchoring */
#define RA3D_INST_SOLID      16u    /* field 5 — filled, not a shell     */
#define RA3D_INST_FULLWARP   32u    /* field 6 — texture wraps the block */
#define RA3D_INST_EMPTY_SHIFT 8     /* bits 8-10: emptyColor 0-4 (field 23) */
/* 3dSen's shadow participation, resolved per instance at build time
 * as 3dSen resolves it:
 *   NOCAST     the pattern's `!cast` tag, its layer's CastShadow off, UI,
 *              translucent (no caster pass) or hidden
 *   NORECV     `!recv`/`!receiv`, its layer's RecvShadow off, or UI
 *   SHADOWONLY renderStyle 2: shadows only — casts, never drawn
 *   HIDDEN     renderStyle 0: renderer disabled — neither drawn nor cast */
#define RA3D_INST_NOCAST     (1u << 11)
#define RA3D_INST_NORECV     (1u << 12)
#define RA3D_INST_SHADOWONLY (1u << 13)
#define RA3D_INST_HIDDEN     (1u << 14)
/* rotation order of an instance whose Offset/Rot/Pivot were converted
 * from 3dSen's frame (knob unity_frame = 1). Neither bit = the legacy
 * Rz*Ry*Rx of the Python prototype, on unconverted values.
 *   ROT_XYZ  Rx*Ry*Rz — the default: R(right, x) * R(up, y) * R(forward, z)
 *   ROT_YXZ  Ry*Rx*Rz — the `_gaxis` tag: Euler angles applied Z, X, Y */
#define RA3D_INST_ROT_XYZ    (1u << 15)
#define RA3D_INST_ROT_YXZ    (1u << 16)
/* layer UI — 3dSen draws it on a camera-locked container, so the
 * renderer exempts it from the scene camera (and it never casts
 * or receives, like every UI shape). */
#define RA3D_INST_UI         (1u << 17)
/* a shape inserted by Lua (Frame:AddNewShape) or the Backdrop box */
#define RA3D_INST_INSERTED   (1u << 18)
/* mesh with 3dSen's MARCHING (the pattern's mode is MARCHING: the
 * pattern's `rm` is 2, or 0 with the `retina` knob on) — ra3d_vox.h */
#define RA3D_INST_MARCHING   (1u << 19)
/* pattern-level fills share one voxel block per tile identity,
 * as 3dSen does (knob `tile_share`, default on) — ra3d_vox.h */
#define RA3D_INST_TILESHARE  (1u << 20)
/* A sprite's depth order, as 3dSen lays out each sprite tile: local
 * z += (OAM index & 0x3F) * 0.001 + (behind BG ? 0.1 : -0.1) (3dSen's frame,
 * +Z away from the viewer). A sprite behind the background thus sits 0.1 px BEHIND its pattern
 * plane and one in front 0.1 px ahead, so a behind-BG sprite whose face is
 * coplanar with a background face (Duck Hunt's dog rising out of the grass)
 * loses cleanly instead of z-fighting. Kept per instance here: BEHIND = any
 * of its tiles is behind (Shape.hidden), ORDER = its lowest OAM index.
 * Applied in ra3d_geo_instances. */
#define RA3D_INST_BEHIND     (1u << 21)
#define RA3D_INST_ORDER_SHIFT 22    /* bits 22-27: OAM index & 0x3F */

/* what 3dSen's `Shape` (shape2D) knows about a matched region,
 * which the profile Lua reads: the TIGHT pixel box (Tile2D start/end, i.e. the
 * opaque pixels' extents — an all-blank tile contributes start 7 / end 0, as
 * Tile2D.LoadRaw leaves it), the tile box, the first tile's palette, whether
 * it is background and whether any of its sprite tiles is behind the
 * background (Shape.hidden), and its distinct identities (for Completed). */
typedef struct
{
   int16_t  px0, py0, px1, py1;   /* inclusive, NES screen px              */
   int16_t  tx0, ty0;             /* tile box origin, px / 8                */
   uint16_t tw, th;               /* tile box size (Shape.tSize)            */
   uint16_t idents;               /* distinct identities in the region      */
   uint8_t  pal;                  /* palIndex: 0-3 bg, 4-7 sprite           */
   uint8_t  flags;                /* bit0 background, bit1 hidden           */
   uint32_t pattern;              /* index into the profile's patterns      */
   uint32_t cell_base;            /* the region's own tw*th cells in
                                   * Ra3dGeoFrame.cells (scene CHR); a textured
                                   * variant draws a copy */
   uint32_t tile_first, tile_count;  /* its scene tiles, in
                                   * Ra3dGeoFrame.rtile (a tile joined by
                                   * SpriteTolerance or from a row at another
                                   * fine-X sits off the 8-px cell grid, so
                                   * the cells alone do not name it)        */
} Ra3dGeoRegion;

typedef struct
{
   Ra3dGeoInstance *instances;
   uint32_t         instance_count, instance_cap;
   Ra3dGeoCell     *cells;
   uint32_t         cell_count, cell_cap;

   uint32_t         frame;
   /* stats, for the beacon and for the parity gate against the Python */
   uint32_t         scene_tiles, non_empty, candidates;
   uint32_t         pattern_instances, multi_tile, clipped, fallbacks, covered;
   uint32_t         flattened;        /* shapes stood upright by flat_shapes */
   uint32_t         variants;         /* instances from Pattern3D index >= 1 */
   uint32_t         lua_hidden;       /* instances a hiding script turned off */
   /* per instance, the profile Pattern3D it was built from (an index
    * for ra3d_profile_shape_*), RA3D_NO_SHAPE for a fallback slab. Parallel
    * to `instances`, so the GPU-facing Ra3dGeoInstance stays 112 bytes. */
   uint32_t        *shape_of;
   uint32_t         shape_of_cap;
   /* per instance, its region (index into `regions`), RA3D_NO_SHAPE for
    * a fallback slab, an inserted shape or the Backdrop. Parallel to
    * `instances`, like shape_of. */
   uint32_t        *region_of;
   uint32_t         region_of_cap;
   Ra3dGeoRegion   *regions;
   uint32_t         region_count, region_cap;
   double           match_ms;
   /* every Direct-colour Pattern3D texture of the profile, ARGB
    * copied from the profile when it changes;
    * `dtex_gen` bumps on every copy so the renderer re-uploads only then. */
   uint32_t        *dtex;
   uint32_t         dtex_n, dtex_cap, dtex_gen, dtex_serial;
   /* this frame's EXTRA atlas tiles, already as pixel values
    * (64 B each, 0-7), indexed from the scene's AtlasCount: the textured
    * Pattern3Ds' tiles and the Lua inserts' / Backdrop's CHR. `tt_gen`/
    * `tt_base` (per profile texture tile) dedupe a tile within the
    * frame; only the tiles a cell draws are appended. */
   uint8_t         *xpx;
   uint32_t         xpx_n, xpx_cap;
   uint32_t        *tt_gen, *tt_base;
   uint32_t         tt_cap, tt_stamp;

   uint32_t        *rtile;     /* scene tile indices, per region   */
   uint32_t         rtile_n, rtile_cap;
   void            *scratch;   /* opaque per-frame working set, reused */
} Ra3dGeoFrame;

/* ----------------------------------------------------------------- the knobs
 * The four values that are OURS, not the format's, plus the matcher's
 * two guards. Read from Documents/RetroArch/system/3dsen/3dsen.cfg at load so
 * they can be tuned without a rebuild. */
typedef struct
{
   float size_z_scale;      /* world px per SizeZ unit          (default 1.0) */
   float layer_z[6];        /* UNIDENTIFIED/UI/L1..L4 front-plane z, world px */
   float fallback_size_z;   /* depth of an unmatched cell's slab (default 8)  */
   int   pattern3d_index;   /* -1 (default) = EVERY Pattern3D of the
                             * matched pattern, as 3dSen draws them
                             * (Shape.InsCount = refPattern.count); N >= 0 =
                             * only index N (the earlier behaviour was 0) */
   /* retired these three. Rounds 2-4 placed a pattern's WxH grid at an
    * anchor and demanded every constrained cell match, so it needed a probe
    * budget and a floor on how much of a clipped instance had to be visible.
    * The matcher is a region grow now — there is no anchor, no clipping and no
    * probing. They do nothing; reports their cfg keys as legacy
    * and ignores them. */
   float clip_ratio;
   int   min_clip_cells;
   int   probes;
   int   enable_fallback;   /* emit 1x1 slabs for unmatched cells (default 1) */
   /* 3dSen profiles build a DIORAMA: roughly half of a game's shapes
    * carry rot.x = +/-90, i.e. they are laid FLAT (floors, tables, the ice, a
    * boxing ring's canvas) and 3dSen's own camera looks down on them. Our panel
    * is world-locked and the eye is on its normal, so a laid-flat plate is seen
    * edge-on and its skirt — which repeats the nearest edge texel — paints
    * `size_z` pixels of ONE solid colour across the screen. Hundreds of them
    * merge into a slab that swallows the whole picture.
    *   1 (default) — a shape whose |rot.x| is within 45 deg of 90 is stood
    *                 upright (rot zeroed) and extrudes backwards like every
    *                 other shape: the picture registers with the 2D frame and
    *                 nothing can occlude it.
    *   0           — the profile's rotations verbatim (the diorama), for use
    *                 with a camera that actually looks down at it.
    *  -1 (default) — auto: 0 (3dSen's rotations as authored) unless the
    *                 profile is a LocalCam floor diorama whose LocalCam is NOT
    *                 engaged (cfg `localcam = 0`), i.e. exactly the edge-on case
    *                 this rule was written for. Since our camera gives every 3dSen
    *                 profile a camera that sees its rotations from the angle
    *                 they were authored for, flattening is the exception.     */
   int   flat_shapes;
   /* Runtime, set by the shell every frame (not a cfg key): 1 while the
    * LocalCam tabletop is engaged, 0 when it is not, -1 unknown (mac tools) =
    * assume it follows the profile's own LocalCam verdict. */
   int   localcam_active;
   /* 3dSen authors Pattern3D Offset/Rot/Pivot in 3dSen's frame (+Y up,
    * +Z INTO the screen, pivot measured from the bottom/near corner, rotation
    * Rx*Ry*Rz); NES world here is +Y down, +Z toward the viewer. The map
    * (x, y, z) -> (x, -y, -z) is a 180 deg turn about X, so:
    *   offset (x, -y, -z); pivot (x, 1-y, 1-z); rot (x, -y, -z), order kept.
    *   1 (default) — convert (3dSen's picture);
    *   0           — the earlier verbatim values and Rz*Ry*Rx order.      */
   int   unity_frame;
   /* Setting.EmptyTile. -1 (default) = the profile's own (see
    * ra3d_profile_empty_tile), 0 = off (earlier: blank tiles never match),
    * 1 = on. */
   int   empty_tile;
   /* run the profile's Lua (1, default) or keep the static
    * Stage-0 scrapers of (0). cfg key `lua`. */
   int   lua;
   /* Runtime, set by the shell (not a cfg key): 1 while a Lua VM is live for
    * this profile. Then build_frame drops the static hides and emits
    * renderStyle-0 alternates as HIDDEN instances, because a script may
    * re-enable them (3dSen copies renderStyle every frame, then the scripts
    * run). */
   int   lua_active;
   /* Runtime: the scripts' Setting.LocalCam, which replaces the scrape
    * in flat_shapes' auto verdict while lua_active. */
   int   lua_localcam;
   /* place L1..L4 boxes by the profile's own _Setting_.Layer
    * (Offset + Aligned FRONT/CENTER/BACK) as 3dSen does
    * (low z = Offset + SizeZ/2*(coef-1), coef 1/0/-1),
    * instead of the invented layer_z_* spacing with every box centred on its
    * plane. 1 (default) when the profile carries a LayerConfig; 0 =
    * the earlier layer_z_* placement. cfg key `profile_layers`. The UI layer
    * keeps layer_z_ui (it is drawn on the camera-locked panel). */
   int   profile_layers;
   /* 3dSen's rules for which tiles the matcher
    * sees and which are neighbours:
    *   - a tile outside Setting.Clipping is dropped (x+8 > c0, x <= 256-c2,
    *     y+8 > c3, y <= 248-c1), and a sprite at y >= 240;
    *   - background tiles are bucketed on World2Grid ((x+7)>>3)+1 and
    *     neighbour by grid cell (a later tile in the same cell replaces the
    *     earlier one), so rows at different fine-X still join;
    *   - sprites join within Setting.SpriteTolerance px of
    *     every sprite tile, and sizes are counted on (x>>3, y>>3);
    *   - SameBgPalette / SameSpPalette gate a join on equal palettes;
    *   - a pass-1 region that fails the gate keeps its tiles until the end
    *     of pass 1, so later pass-1 seeds cannot take them.
    * 1 (default) = those rules; 0 = the earlier exact-8-px adjacency (
    * deviation 1). cfg key `grid_match`. */
   int   grid_match;
   /* Runtime (not a cfg key): the scripts' current Setting.Clipping, which
    * is what Converter culls by. cull_set 0 = use the profile's own
    * (_Setting_.Clipping, else 3dSen's default 0.1/8.1/8.1/0.1). */
   int   cull_set;
   float cull[4];
   /* which RGB a NES colour index draws in 3dSen mode.
    * 1 (default) = 3dSen's own table (the
    * colours its renderer and scripts see); 0 = the core's palette (the
    * flat 2D picture's colours, earlier). cfg key `nes_palette`. */
   int   nes_palette;
   /* 3dSen's RenderMode setting, which v2's UI calls "Retina".
    * A Pattern3D's `rm` field forces its mesher (1 GREEDY, 2 MARCHING,
    * 3 GREEDY_MULTICOLOR); rm 0 follows this setting. 0 (default, v2's
    * default) = GREEDY; 1 = MARCHING for every rm-0 shape. cfg key `retina`. */
   int   retina;
   /* 1 (default) = a pattern-level fill (cylinders, CUBE,
    * fullWarp Default) shares one voxel block per tile identity, as 3dSen's
    * renderer does — SMB's hill reads as terraces; 0 = every cell
    * fills its own block (earlier: smooth slopes). cfg key `tile_share`. */
   int   tile_share;
} Ra3dKnobs;

/* 3dSen's NES palette, ARGB (0xRRGGBB | 0xFF000000). Emphasis bits are ignored,
 * as 3dSen ignores them. */
static const uint32_t RA3D_NES_PALETTE[64] = {
   0xFF788084u, 0xFF0000FCu, 0xFF0000C4u, 0xFF4028C4u, 0xFF94008Cu, 0xFFAC0028u, 0xFFAC1000u, 0xFF8C1800u,
   0xFF503000u, 0xFF007800u, 0xFF006800u, 0xFF005800u, 0xFF004058u, 0xFF000000u, 0xFF000000u, 0xFF000000u,
   0xFFBCC0C4u, 0xFF0078FCu, 0xFF0088FCu, 0xFF6848FCu, 0xFFDC00D4u, 0xFFE40060u, 0xFFFC3800u, 0xFFE46018u,
   0xFFAC8000u, 0xFF00B800u, 0xFF00A800u, 0xFF00A848u, 0xFF008894u, 0xFF2C2C2Cu, 0xFF000000u, 0xFF000000u,
   0xFFFCF8FCu, 0xFF38C0FCu, 0xFF6888FCu, 0xFF9C78FCu, 0xFFFC78FCu, 0xFFFC589Cu, 0xFFFC7858u, 0xFFFCA048u,
   0xFFFCB800u, 0xFFBCF818u, 0xFF58D858u, 0xFF58F89Cu, 0xFF00E8E4u, 0xFF606060u, 0xFF000000u, 0xFF000000u,
   0xFFFCF8FCu, 0xFFA4E8FCu, 0xFFBCB8FCu, 0xFFDCB8FCu, 0xFFFCB8FCu, 0xFFF4C0E0u, 0xFFF4D0B4u, 0xFFFCE0B4u,
   0xFFFCD884u, 0xFFDCF878u, 0xFFB8F878u, 0xFFB0F0D8u, 0xFF00F8FCu, 0xFFC8C0C0u, 0xFF000000u, 0xFF000000u,
};

/* The RGB of NES colour `e` (0-63) as 3dSen mode draws it. */
static inline uint32_t ra3d_nes_rgb(const Ra3dKnobs *k, const uint32_t *core_rgb, unsigned e)
{
   e &= 63u;
   if (!k || k->nes_palette) return RA3D_NES_PALETTE[e];
   return core_rgb ? core_rgb[e] : 0xFF000000u;
}

void ra3d_knobs_defaults(Ra3dKnobs *k);
/* Applies "key = value" lines from a 3dsen.cfg text buffer. Unknown keys are
 * ignored and reported in *unknown so the beacon can name a typo. */
void ra3d_knobs_parse(Ra3dKnobs *k, const char *text, size_t len, int *unknown);
/* the earlier keys (invented spacing and guards,
 * flat_shapes / depth_scale, plane_mode, and earlier
 * pattern3d_index) no longer describe 3dSenVR's behaviour; an old 3dsen.cfg
 * that still carries them would force a pre-parity look (flat_shapes = 1
 * stands up every profile floor). They are IGNORED: the knob keeps its
 * compiled default. ra3d_knobs_is_legacy names them; the _ex parse calls
 * `legacy(key, ud)` once per legacy key present (first occurrence), so the
 * shell can beacon each one. */
int  ra3d_knobs_is_legacy(const char *key);
void ra3d_knobs_parse_ex(Ra3dKnobs *k, const char *text, size_t len, int *unknown,
                         void (*legacy)(const char *key, void *ud), void *ud);

/* -------------------------------------------------------------- the profile */

typedef struct Ra3dProfile Ra3dProfile;

/* Parses a .3dn from memory. Returns NULL and fills err on failure. */
Ra3dProfile *ra3d_profile_parse(const void *data, size_t len,
                                char *err, size_t errlen);
void         ra3d_profile_free(Ra3dProfile *p);
uint32_t     ra3d_profile_pattern_count(const Ra3dProfile *p);
uint32_t     ra3d_profile_shape_count(const Ra3dProfile *p);
uint32_t     ra3d_profile_variant_count(const Ra3dProfile *p);
/* The profile's own static light, _Setting_.Light: fills
 * `dir` with Light.Direction in 3dSen's frame and `col` with the sRGB
 * Light.Color. Returns bit0 if a Direction was present, bit1 for a Color.
 * (3dSen deep-copies _Setting_ over the user's settings but re-pins the
 * user's Intensity, so a profile can set direction and colour only.) */
int          ra3d_profile_light(const Ra3dProfile *p, float dir[3], float col[3]);
/* the z (NES world, +Z toward the viewer) of the CENTRE of a
 * `layer` box `d` px deep — the profile's LayerConfig when k->profile_layers
 * and the profile has one (UI excepted), else k->layer_z[layer]. */
float        ra3d_layer_centre_z(const Ra3dProfile *p, const Ra3dKnobs *k, int layer, float d);
/* The profile's static _Setting_.Clipping: 3dSen's
 * four screen-edge insets in NES px, in ITS order — [0] left,
 * [1] bottom (3dSen's +Y is up, so it trims the HIGH NES rows), [2] right,
 * [3] top. Returns 1 when the profile carries one (missing components are 0,
 * the file omits zeros), 0 otherwise. Lua-set Clipping (Punch-Out's
 * widened -128,-80,-128,0) is not visible here. */
int          ra3d_profile_clipping(const Ra3dProfile *p, float clip[4]);
/* the per-ZLayer shadow flags (index 0 UNIDENTIFIED, 1 UI, 2-5 L1-L4)
 * as 3dSen ends up with them for this profile: the defaults are
 * Cast = L1 only, Recv = L1-L4, then the
 * profile's own Lua `Start()` writes `Setting.Layer[N].CastShadow/RecvShadow
 * = true|false` (SMB: L2 casts). Only literal
 * assignments inside a `function Start()` body are honoured, first one per
 * flag wins; End()/Update() writes and conditionals are not evaluated.
 * Returns a bitmask of the layers the Lua touched. NULL p -> the defaults. */
int          ra3d_profile_layer_shadow(const Ra3dProfile *p, uint8_t cast[6],
                                       uint8_t recv[6]);
/* 3dSen's `Setting.LocalCam` (alias TopDownCam) — the NES screen laid
 * as a FLOOR. Never a static constant in the profiles that use it, so this is
 * a scrape (Lua is not run), first match of, in order:
 *   - a literal `= true` inside `function UpdateS()` (Lunar Pool: on whenever
 *     its tagged shape is on screen)                              -> on, src 8
 *   - a literal `= true|false` inside `function Start()` (Punch-Out) -> src 4
 *   - a scene-gated write (`= scene == N`): on only when a camera script's
 *     Start() also declares a floor pose (a `...Rot... = {x=<-10 or less>, ...}`
 *     table) — Ice Hockey on, Zelda II / Spike V-Ball off       -> src 16
 *   - _Setting_ field 25 (static; 3 of the 101 official profiles)  -> src 2
 * `*rotx` gets that floor pose's Rot.x (3dSen degrees: -55 Hockey, -65
 * Punch-Out; 0 = straight down when no pose is declared) and `*dist` its
 * Camera.Distance when the same Start() declares one AND the script actually
 * assigns Camera.Distance (Hockey writes a local copy, so 3dSen keeps its
 * default 189.65), else 0. Returns bit0 = on, | the source bit. */
int          ra3d_profile_localcam(const Ra3dProfile *p, float *rotx, float *dist);
/* 3dSen's Setting.EmptyTile for this profile — with it on, blank
 * (all-colour-0) background tiles are real matcher input
 * and join regions whose patterns contain blank cells; off, they are not in
 * the frame at all. Resolution: a literal `Setting.EmptyTile = true|false` in
 * a `function Start()`, else a literal `= true` anywhere else (Ice Hockey sets
 * it per scene, on in the rink), else _Setting_ field 24. Returns 1/0. */
int          ra3d_profile_empty_tile(const Ra3dProfile *p);
/* a profile Pattern3D's static CData[0..7] (index = Ra3dGeoFrame
 * shape_of[]). Returns 0 for an out-of-range index (out zeroed). */
int          ra3d_profile_shape_cdata(const Ra3dProfile *p, uint32_t shape,
                                      float out[8]);

/* ------------------------------------------------------------- the per-frame
 * Matches `scene` against `prof` and fills `out` with the instance array.
 * `out` owns growable buffers: zero it once, pass it every frame, free it with
 * ra3d_frame_release at the end. Returns 1 on success. */
int  ra3d_build_frame(const Ra3dProfile *prof, const Ra3dScene *scene,
                      const Ra3dKnobs *k, Ra3dGeoFrame *out);
void ra3d_frame_release(Ra3dGeoFrame *f);

#ifdef __cplusplus
}
#endif

/* ========================================================================== */
#ifdef RA3D_SHAPE_IMPLEMENTATION

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>
#include <time.h>

#define RA3D_SCREEN_W 256
#define RA3D_SCREEN_H 240

/* ------------------------------------------------------------ tiny vectors */

#define RA3D_VEC(T) struct { T *v; uint32_t n, cap; }
static int ra3d_grow(void **v, uint32_t *cap, uint32_t need, size_t esz)
{
   uint32_t c = *cap ? *cap : 64;
   void *p;
   if (need <= *cap) return 1;
   while (c < need) c *= 2;
   p = realloc(*v, (size_t)c * esz);
   if (!p) return 0;
   *v = p; *cap = c;
   return 1;
}
#define RA3D_PUSH(vec, val, esz) \
   (ra3d_grow((void**)&(vec).v, &(vec).cap, (vec).n + 1, esz) \
      ? ((vec).v[(vec).n++] = (val), 1) : 0)

/* ------------------------------------------------------- protobuf (proto2) */

typedef struct { const uint8_t *p, *end; } ra3d_rd;

static int ra3d_uv(ra3d_rd *r, uint64_t *out)
{
   uint64_t v = 0; int s = 0;
   while (r->p < r->end)
   {
      uint8_t c = *r->p++;
      v |= (uint64_t)(c & 0x7F) << s;
      if (!(c & 0x80)) { *out = v; return 1; }
      s += 7;
      if (s > 63) return 0;
   }
   return 0;
}

/* Skips the body of a group whose START_GROUP key has just been read, leaving
 * r->p just past its END_GROUP. `field` is the group's field number. */
static int ra3d_skip_group(ra3d_rd *r, uint32_t field);

/* Reads one field. Returns 0 at end / on error. For wt2 and wt3 the payload is
 * handed back as [*pl, *pl + *pn); for wt3 that excludes the END_GROUP key. */
static int ra3d_field(ra3d_rd *r, uint32_t *field, uint32_t *wt,
                      uint64_t *val, const uint8_t **pl, size_t *pn)
{
   uint64_t key, len;
   if (r->p >= r->end) return 0;
   if (!ra3d_uv(r, &key)) return 0;
   *field = (uint32_t)(key >> 3);
   *wt    = (uint32_t)(key & 7);
   if (*field == 0) return 0;
   *val = 0; *pl = NULL; *pn = 0;
   switch (*wt)
   {
      case 0: return ra3d_uv(r, val);
      case 1: if (r->end - r->p < 8) return 0; r->p += 8; return 1;
      case 5: if (r->end - r->p < 4) return 0;
              memcpy(val, r->p, 4); r->p += 4; return 1;
      case 2:
         if (!ra3d_uv(r, &len)) return 0;
         if ((size_t)(r->end - r->p) < len) return 0;
         *pl = r->p; *pn = (size_t)len; r->p += len;
         return 1;
      case 3:
      {
         const uint8_t *start = r->p;
         ra3d_rd probe = *r;
         if (!ra3d_skip_group(&probe, *field)) return 0;
         /* probe.p is past END_GROUP; back off its key to bound the payload */
         *pl = start;
         *pn = (size_t)(probe.p - start);
         /* trim the END_GROUP key (1 byte for field < 16, else varint) */
         {
            const uint8_t *q = probe.p - 1;
            while (q > start && (*(q - 1) & 0x80)) q--;
            *pn = (size_t)(q - start);
         }
         r->p = probe.p;
         return 1;
      }
      case 4: return 0;   /* stray END_GROUP */
      default: return 0;
   }
}

static int ra3d_skip_group(ra3d_rd *r, uint32_t field)
{
   for (;;)
   {
      uint64_t key, len;
      if (!ra3d_uv(r, &key)) return 0;
      {
         uint32_t f = (uint32_t)(key >> 3), wt = (uint32_t)(key & 7);
         if (wt == 4) return f == field;
         switch (wt)
         {
            case 0: { uint64_t v; if (!ra3d_uv(r, &v)) return 0; } break;
            case 1: if (r->end - r->p < 8) return 0; r->p += 8; break;
            case 5: if (r->end - r->p < 4) return 0; r->p += 4; break;
            case 2:
               if (!ra3d_uv(r, &len)) return 0;
               if ((size_t)(r->end - r->p) < len) return 0;
               r->p += len;
               break;
            case 3: if (!ra3d_skip_group(r, f)) return 0; break;
            default: return 0;
         }
      }
   }
}

static float ra3d_f32(uint64_t bits)
{
   float f; uint32_t u = (uint32_t)bits;
   memcpy(&f, &u, 4);
   return f;
}

/* vec3 is a submessage {1: f32 x, 2: f32 y, 3: f32 z}. */
static void ra3d_vec3(const uint8_t *p, size_t n, float *out, float dflt)
{
   ra3d_rd r; uint32_t f, wt; uint64_t v; const uint8_t *pl; size_t pn;
   out[0] = out[1] = out[2] = dflt;
   if (!p) return;
   r.p = p; r.end = p + n;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
      if (wt == 5 && f >= 1 && f <= 3) out[f - 1] = ra3d_f32(v);
}

/* ----------------------------------------------------------- the tile key */

/* the .3dn tile key: the entry is the tile's raw 16 CHR bytes, not a hash. */
#define RA3D_TILEKEY 0x000708FACD884A5AULL
#define RA3D_TILEBITS 26

static uint64_t ra3d_tile_decode(uint64_t v)
{
   return ((v << RA3D_TILEBITS) | (v >> (64 - RA3D_TILEBITS))) ^ RA3D_TILEKEY;
}

/* --------------------------------------------------------- profile storage */

typedef struct { uint8_t chr[16]; uint8_t fx, fy; } Ra3dVariant;

typedef struct
{
   uint16_t gx, gy;
   uint32_t var_first;      /* into prof->cellvars */
   uint16_t var_count;
} Ra3dPatCell;

typedef struct
{
   float    size_z;
   float    scale[3], rot[3], offset[3], pivot[3];
   float    alpha;
   uint8_t  geo, layer;
   uint8_t  fill_flags;     /* RA3D_INST_ANTISHADOW | FLIP | SOLID | FULLWARP */
   uint8_t  empty_color;    /* 0-4; 4 never matches a 2-bit pixel = none empty */
   uint8_t  render_style;   /* field 18: 0 hidden, 1 normal, 2 shadow only */
   uint8_t  render_mode;    /* field 13 `rm`: 0 setting, 1 GREEDY, 2 MARCHING, 3 GREEDY_MULTICOLOR */
   uint8_t  tag_nocast;     /* field 20 tags: `!cast`                      */
   uint8_t  tag_norecv;     /*                `!recv` / `!receiv`          */
   uint8_t  tag_gaxis;      /*                `_gaxis`: Euler order, not the default */
   uint8_t  lua_hidden;     /* a linked script's UpdateS hides it unconditionally */
   uint8_t  index;          /* position in its pattern's Pattern3D list */
   uint16_t tag_len;        /* field 20 verbatim, in prof->tagpool          */
   uint32_t tag_off;
   uint32_t pattern;        /* index of its pattern in prof->patterns */
   /* field 19, the shape's texture, when it is a Direct-colour (ARGB) texture:
    * 3dSen then draws those colours, not the palette.
    * dtex_w == 0: none (Index textures are not read yet). */
   uint32_t dtex_first;     /* into prof->dtex */
   uint16_t dtex_w, dtex_h;
   /* the texture as 8x8 TILES of 3dSen pixel values (Index:
    * 2 bits + the extra bit, 0-7; Direct: presence, mapped so emptyColor
    * still means empty), 64 bytes each in prof->ttiles, row-major
    * tt_gw x tt_gh. 3dSen builds the mesh from `tex`, not the frame's CHR
    * so a textured Pattern3D draws THESE pixels.
    * tt_gw == 0: no texture. */
   uint32_t tt_first;
   uint8_t  tt_gw, tt_gh;
   /* shape.CData[0..7]: [i<4] = element [3,i] of the field-16 4x4 matrix,
    * [i>=4] = element [3,i&3] of the field-17 one — row 3 of each
    * (fields 13..16 = m30..m33). Static script data (Punch-Out's scene number
    * in CData[7], its item->panel link in CData[0]). */
   float    cdata[8];
} Ra3dShape3D;

typedef struct
{
   uint32_t id;
   uint16_t w, h;                    /* the AUTHORED grid; informational only  */
   uint32_t cell_first, cell_count;
   uint16_t cw, ch;                  /* constraintSize; 99 = unrestricted      */
   uint8_t  skip_geo;                /* Pattern.skipGeo — membership, no links */
   uint32_t ident_first, ident_count;/* sorted distinct variant ids (tiles2D)  */
   uint32_t shape_first, shape_count;
} Ra3dPattern;

/* One entry of Pattern.CreateLinks' adjacency table, flattened across every
 * pattern in the profile. `bd` is the second identity with the direction in its
 * top bit: 0 = b sits to a's RIGHT, 1 = b sits BELOW a. */
typedef struct { uint32_t p, a, bd; } Ra3dLink;

/* one top-level `Script` of the profile, verbatim, in file order
 * (= 3dSen's sorted order). Strings live in
 * prof->scriptpool. */
typedef struct
{
   uint32_t name_off, name_len, src_off, src_len, tag_off, tag_len;
   uint8_t  enabled;
} Ra3dScript;

struct Ra3dProfile
{
   RA3D_VEC(Ra3dVariant)  vars;
   RA3D_VEC(uint32_t)     cellvars;
   RA3D_VEC(Ra3dPatCell)  cells;
   RA3D_VEC(Ra3dShape3D)  shapes;
   RA3D_VEC(Ra3dPattern)  patterns;
   RA3D_VEC(uint32_t)     dtex;      /* Direct textures, ARGB */
   RA3D_VEC(uint8_t)      ttiles;    /* texture tiles, 64 B each */
   uint32_t               serial;    /* unique per parse */

   /* the matcher's two indexes, built once at load */
   RA3D_VEC(Ra3dLink)     links;     /* sorted + uniqued, then hashed         */
   uint32_t *lhash; uint32_t lhash_mask;
   RA3D_VEC(uint32_t)     idents;    /* per-pattern sorted distinct variants  */
   /* parallel to idents — the LAST row-major cell (gy*w + gx) of
    * the pattern holding that identity. 3dSen keys a Pattern3D's Tile3D
    * meshes by Tile2D (one mesh per tile identity, placed at the last grid
    * cell holding it), and draws that mesh for
    * each tile of the shape: a tile draws the texture block at ITS identity's
    * cell, wherever the region sits in the pattern. */
   RA3D_VEC(uint32_t)     identcell;
   RA3D_VEC(uint32_t)     keypat;    /* CSR values: pattern ids per variant   */
   uint32_t *keypat_off;             /* vars.n + 1 offsets into keypat        */

   /* the whole grid of the pattern being parsed, wildcards included, because
    * t_size arrives after the grid in file order and links need both */
   RA3D_VEC(Ra3dPatCell)  gtmp;

   /* variant interning: open-addressed, key is the 18 identity bytes */
   uint32_t *vhash; uint32_t vhash_mask;

   /* Tile2D id -> variant run, profile-global */
   uint32_t *t2d_first; uint16_t *t2d_count; uint32_t t2d_cap;

   char title[64];
   int      light_flags;               /* bit0 dir, bit1 colour */
   float    light_dir[3], light_col[3];
   int      same_bg_pal, same_sp_pal;  /* _Setting_ 18 / 37  */
   int32_t  sp_tol, scan_dir;          /* _Setting_ 19 / 20  */
   int      clip_set;                  /* _Setting_.Clipping present */
   float    clip[4];
   uint8_t  layer_cast[6], layer_recv[6];
   int      layer_set;                       /* _Setting_.Layer seen */
   float    layer_off[6];                    /* layer Offset, 3dSen +Z = into screen   */
   uint8_t  layer_align[6];                  /* layer Aligned 0 FRONT 1 CENTER 2 BACK  */
   int      layer_lua;                       /* layers a Start() touched */
   /* LocalCam scrape: -1 = not seen */
   int      lc_static, lc_start, lc_updates, lc_scene;
   int      lc_pose_set;  float lc_rotx, lc_dist;
   RA3D_VEC(char)         tagpool;   /* every Pattern3D's TagStr */
   RA3D_VEC(char)         hidetags;  /* TagStrs of hiding scripts, NUL-separated */
   uint32_t hide_scripts, hide_star; /* count, and how many tag `*` */
   uint32_t lua_hidden;              /* Pattern3Ds hidden by them          */
   /* Setting.EmptyTile: _Setting_ field 24, then the Lua scrape */
   int      et_static, et_start, et_dyn;
   RA3D_VEC(Ra3dScript)   scripts;   /* every Script, file order        */
   RA3D_VEC(char)         scriptpool;
   uint32_t max_cells;      /* biggest constrained-cell count, for scratch */
   uint32_t max_cands;      /* biggest per-variant pattern list, for scratch */
};

/* (p, a, b, dir) membership test over prof->links. */
static uint32_t ra3d_link_hash(uint32_t p, uint32_t a, uint32_t bd)
{
   uint32_t h = 2166136261u;
   h = (h ^ p)  * 16777619u;
   h = (h ^ a)  * 16777619u;
   h = (h ^ bd) * 16777619u;
   h ^= h >> 15;
   return h;
}

static int ra3d_is_link(const Ra3dProfile *pr, uint32_t p,
                        uint32_t k1, uint32_t k2, int dir)
{
   uint32_t a, bd, i;
   if (!pr->lhash) return 0;
   if (dir == 0)      { a = k1; bd = k2; }
   else if (dir == 1) { a = k1; bd = k2 | 0x80000000u; }
   else if (dir == 2) { a = k2; bd = k1 | 0x80000000u; }
   else               { a = k2; bd = k1; }
   i = ra3d_link_hash(p, a, bd) & pr->lhash_mask;
   for (;;)
   {
      uint32_t e = pr->lhash[i];
      if (e == 0xFFFFFFFFu) return 0;
      if (pr->links.v[e].p == p && pr->links.v[e].a == a &&
          pr->links.v[e].bd == bd) return 1;
      i = (i + 1) & pr->lhash_mask;
   }
}

/* Pattern.tiles2D.Contains — binary search of the sorted ident run. */
static int ra3d_has_ident(const Ra3dProfile *pr, const Ra3dPattern *pat,
                          uint32_t v)
{
   uint32_t lo = 0, hi = pat->ident_count;
   while (lo < hi)
   {
      uint32_t mid = lo + ((hi - lo) >> 1);
      uint32_t x = pr->idents.v[pat->ident_first + mid];
      if      (x < v) lo = mid + 1;
      else if (x > v) hi = mid;
      else return 1;
   }
   return 0;
}

static uint32_t ra3d_hash18(const uint8_t *b)
{
   uint32_t h = 2166136261u; int i;
   for (i = 0; i < 18; i++) { h ^= b[i]; h *= 16777619u; }
   return h ? h : 1u;
}

static uint32_t ra3d_intern_variant(Ra3dProfile *p, const uint8_t chr[16],
                                    int fx, int fy)
{
   uint8_t key[18];
   uint32_t h, i;
   memcpy(key, chr, 16); key[16] = (uint8_t)fx; key[17] = (uint8_t)fy;
   h = ra3d_hash18(key);
   i = h & p->vhash_mask;
   for (;;)
   {
      uint32_t slot = p->vhash[i];
      if (slot == 0xFFFFFFFFu) break;
      if (memcmp(p->vars.v[slot].chr, key, 16) == 0 &&
          p->vars.v[slot].fx == key[16] && p->vars.v[slot].fy == key[17])
         return slot;
      i = (i + 1) & p->vhash_mask;
   }
   {
      Ra3dVariant nv;
      memcpy(nv.chr, chr, 16); nv.fx = (uint8_t)fx; nv.fy = (uint8_t)fy;
      if (!RA3D_PUSH(p->vars, nv, sizeof(Ra3dVariant))) return 0xFFFFFFFFu;
      p->vhash[i] = p->vars.n - 1;
      /* the table is sized generously up front; if it ever fills past 2/3 the
       * profile is far larger than any observed (224 677 defs across ALL 101
       * official profiles), and we simply degrade to more probing. */
      return p->vars.n - 1;
   }
}

static void ra3d_t2d_set(Ra3dProfile *p, uint32_t id, uint32_t first, uint16_t n)
{
   if (id >= p->t2d_cap)
   {
      uint32_t nc = p->t2d_cap ? p->t2d_cap : 256;
      uint32_t *nf; uint16_t *ncnt; uint32_t i;
      while (id >= nc) nc *= 2;
      nf   = (uint32_t*)realloc(p->t2d_first, nc * sizeof(uint32_t));
      ncnt = (uint16_t*)realloc(p->t2d_count, nc * sizeof(uint16_t));
      if (!nf || !ncnt) { free(nf); free(ncnt); return; }
      for (i = p->t2d_cap; i < nc; i++) { nf[i] = 0; ncnt[i] = 0; }
      p->t2d_first = nf; p->t2d_count = ncnt; p->t2d_cap = nc;
   }
   p->t2d_first[id] = first;
   p->t2d_count[id] = n;
}

/* Parses `Tile2D{10: {1: <raw tile>...}}` — the definition's variant list — and
 * appends the interned variant ids to prof->cellvars. */
static uint32_t ra3d_parse_variants(Ra3dProfile *prof, const uint8_t *p,
                                    size_t n, uint16_t *out_count)
{
   ra3d_rd r; uint32_t f, wt; uint64_t v; const uint8_t *pl; size_t pn;
   uint32_t first = prof->cellvars.n;
   uint16_t cnt = 0;
   r.p = p; r.end = p + n;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
   {
      if (f != 1 || wt != 2) continue;
      {
         ra3d_rd q; uint32_t f2, wt2; uint64_t v2; const uint8_t *pl2; size_t pn2;
         uint64_t lo = 0, hi = 0, flip = 0;
         uint8_t chr[16];
         uint32_t id;
         q.p = pl; q.end = pl + pn;
         while (ra3d_field(&q, &f2, &wt2, &v2, &pl2, &pn2))
         {
            if (wt2 != 0) continue;
            if      (f2 == 1) lo = v2;
            else if (f2 == 2) hi = v2;
            else if (f2 == 3) flip = v2;
         }
         lo = ra3d_tile_decode(lo);
         hi = ra3d_tile_decode(hi);
         { int i; for (i = 0; i < 8; i++) chr[i]     = (uint8_t)(lo >> (8 * i)); }
         { int i; for (i = 0; i < 8; i++) chr[8 + i] = (uint8_t)(hi >> (8 * i)); }
         id = ra3d_intern_variant(prof, chr, (int)(flip & 1), (int)((flip >> 1) & 1));
         if (id == 0xFFFFFFFFu) continue;
         if (!RA3D_PUSH(prof->cellvars, id, sizeof(uint32_t))) break;
         cnt++;
      }
   }
   *out_count = cnt;
   return first;
}

static const uint8_t RA3D_ZERO16[16] = {0};

static int ra3d_link_cmp(const void *x, const void *y)
{
   const Ra3dLink *a = (const Ra3dLink*)x, *b = (const Ra3dLink*)y;
   if (a->p  != b->p)  return a->p  < b->p  ? -1 : 1;
   if (a->a  != b->a)  return a->a  < b->a  ? -1 : 1;
   if (a->bd != b->bd) return a->bd < b->bd ? -1 : 1;
   return 0;
}

/* Pattern3D TagStr — split on ',', trimmed, exact match, as 3dSen. */
static void ra3d_shadow_tags(Ra3dShape3D *sh, const char *s, size_t n)
{
   size_t i = 0;
   while (i < n)
   {
      size_t a = i, b;
      while (i < n && s[i] != ',') i++;
      b = i;
      while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) a++;
      while (b > a && (s[b-1] == ' ' || s[b-1] == '\t' || s[b-1] == '\r' || s[b-1] == '\n')) b--;
      if (b - a == 5 && !memcmp(s + a, "!cast", 5)) sh->tag_nocast = 1;
      if ((b - a == 5 && !memcmp(s + a, "!recv", 5)) ||
          (b - a == 7 && !memcmp(s + a, "!receiv", 7))) sh->tag_norecv = 1;
      if (b - a == 6 && !memcmp(s + a, "_gaxis", 6)) sh->tag_gaxis = 1;
      i++;
   }
}

/* literal `Setting.Layer[N].CastShadow = true|false` (or RecvShadow)
 * inside a `function Start()` body; first write per (layer, flag) wins. */
static void ra3d_scrape_layer_shadow(Ra3dProfile *prof, const char *s, size_t n)
{
   size_t i = 0;
   int in_start = 0;
   static const char kSet[] = "Setting.Layer[";
   while (i < n)
   {
      size_t a = i, e;
      while (i < n && s[i] != '\n') i++;
      e = i++;
      while (a < e && (s[a] == ' ' || s[a] == '\t')) a++;
      if (e - a >= 9 && !memcmp(s + a, "function ", 9))
      {
         size_t k = a + 9;
         while (k < e && s[k] == ' ') k++;
         in_start = (e - k >= 6 && !memcmp(s + k, "Start(", 6));
         continue;
      }
      if (!in_start || e - a < sizeof(kSet) - 1 || memcmp(s + a, kSet, sizeof(kSet) - 1))
         continue;
      {
         size_t k = a + sizeof(kSet) - 1;
         int layer, recv, val, bit;
         if (k >= e || s[k] < '0' || s[k] > '5') continue;
         layer = s[k] - '0'; k++;
         if (k + 2 > e || s[k] != ']' || s[k+1] != '.') continue;
         k += 2;
         if (e - k >= 10 && !memcmp(s + k, "CastShadow", 10)) { recv = 0; k += 10; }
         else if (e - k >= 10 && !memcmp(s + k, "RecvShadow", 10)) { recv = 1; k += 10; }
         else continue;
         while (k < e && s[k] == ' ') k++;
         if (k >= e || s[k] != '=') continue;
         k++;
         while (k < e && s[k] == ' ') k++;
         if (e - k >= 4 && !memcmp(s + k, "true", 4)) val = 1;
         else if (e - k >= 5 && !memcmp(s + k, "false", 5)) val = 0;
         else continue;
         bit = 1 << (layer + (recv ? 8 : 0));
         if (prof->layer_lua & bit) continue;      /* first write wins */
         prof->layer_lua |= bit;
         if (recv) prof->layer_recv[layer] = (uint8_t)val;
         else      prof->layer_cast[layer] = (uint8_t)val;
      }
   }
}

/* number after `=` / `,`; returns 1 and advances *k on success */
static int ra3d_lua_num(const char *s, size_t e, size_t *k, float *out)
{
   char buf[32]; size_t i = *k, n = 0; char *end;
   while (i < e && (s[i] == ' ' || s[i] == '\t')) i++;
   while (i < e && n < sizeof(buf) - 1 &&
          ((s[i] >= '0' && s[i] <= '9') || s[i] == '-' || s[i] == '+' || s[i] == '.'))
      buf[n++] = s[i++];
   buf[n] = 0;
   if (!n) return 0;
   *out = strtof(buf, &end);
   if (end == buf) return 0;
   *k = i;
   return 1;
}

/* one profile script's LocalCam evidence (see ra3d_profile_localcam). */
static void ra3d_scrape_localcam(Ra3dProfile *prof, const char *s, size_t n)
{
   size_t i = 0;
   int fn = 0;                 /* 1 Start, 2 UpdateS, 0 other */
   float poses[8]; int np = 0;
   float dists[8]; int nd = 0;
   int writes_dist = 0, best = -1;
   static const char kLC[] = "Setting.LocalCam", kTD[] = "Setting.TopDownCam",
                     kCD[] = "Camera.Distance";
   while (i < n)
   {
      size_t a = i, e, k;
      while (i < n && s[i] != '\n') i++;
      e = i++;
      while (a < e && (s[a] == ' ' || s[a] == '\t')) a++;
      if (e - a >= 9 && !memcmp(s + a, "function ", 9))
      {
         k = a + 9;
         while (k < e && s[k] == ' ') k++;
         fn = (e - k >= 6 && !memcmp(s + k, "Start(", 6)) ? 1
            : ((e - k >= 8 && !memcmp(s + k, "UpdateS(", 8)) ? 2 : 0);
         continue;
      }
      if (e - a >= 2 && s[a] == '-' && s[a + 1] == '-') continue;   /* comment */
      /* Camera.Distance = ...  (an assignment, not a read or a compare) */
      for (k = a; k + sizeof(kCD) - 1 <= e; k++)
         if (!memcmp(s + k, kCD, sizeof(kCD) - 1))
         {
            size_t q = k + sizeof(kCD) - 1;
            while (q < e && s[q] == ' ') q++;
            if (q + 1 < e && s[q] == '=' && s[q + 1] != '=') writes_dist = 1;
            break;
         }
      /* Setting.LocalCam / TopDownCam = <rhs> */
      {
         size_t q = a; int hit = 0;
         if (e - a >= sizeof(kLC) - 1 && !memcmp(s + a, kLC, sizeof(kLC) - 1))
         { q = a + sizeof(kLC) - 1; hit = 1; }
         else if (e - a >= sizeof(kTD) - 1 && !memcmp(s + a, kTD, sizeof(kTD) - 1))
         { q = a + sizeof(kTD) - 1; hit = 1; }
         if (hit)
         {
            while (q < e && s[q] == ' ') q++;
            if (q + 1 < e && s[q] == '=' && s[q + 1] != '=')
            {
               int val = -1;
               q++;
               while (q < e && s[q] == ' ') q++;
               if (e - q >= 4 && !memcmp(s + q, "true", 4)) val = 1;
               else if (e - q >= 5 && !memcmp(s + q, "false", 5)) val = 0;
               else if (e - q >= 5 && !memcmp(s + q, "scene", 5)) prof->lc_scene = 1;
               if (val == 1 && fn == 2) prof->lc_updates = 1;
               if (val >= 0 && fn == 1 && prof->lc_start < 0) prof->lc_start = val;
            }
            continue;
         }
      }
      if (fn != 1) continue;
      /* Start(): `oldRot, oldRot1 = {x=0, y = 0}, {x=-65,y=0}` and
       * `oldDis, oldDis1 = 160, 220` — positional pairs */
      {
         size_t eq = a;
         while (eq < e && s[eq] != '=') eq++;
         if (eq >= e || (eq + 1 < e && s[eq + 1] == '=')) continue;
         {
            int has_rot = 0, has_dis = 0;
            for (k = a; k + 3 <= eq; k++)
            {
               if (!memcmp(s + k, "Rot", 3)) has_rot = 1;
               if (!memcmp(s + k, "Dis", 3)) has_dis = 1;
            }
            if (has_rot && np == 0)
            {
               for (k = eq + 1; k + 2 < e && np < 8; k++)
                  if (s[k] == '{')
                  {
                     size_t q = k + 1; float x;
                     while (q < e && s[q] == ' ') q++;
                     if (q < e && s[q] == 'x')
                     {
                        q++;
                        while (q < e && s[q] == ' ') q++;
                        if (q < e && s[q] == '=')
                        { q++; if (ra3d_lua_num(s, e, &q, &x)) poses[np++] = x; }
                     }
                  }
            }
            else if (has_dis && nd == 0)
            {
               float tmp[8]; int t = 0, ok = 1;
               k = eq + 1;
               while (k < e && t < 8)
               {
                  if (!ra3d_lua_num(s, e, &k, &tmp[t])) { ok = 0; break; }
                  t++;
                  while (k < e && s[k] == ' ') k++;
                  if (k < e && s[k] == ',') { k++; continue; }
                  while (k < e && (s[k] == ' ' || s[k] == '\t' || s[k] == '\r')) k++;
                  if (k < e) ok = 0;
                  break;
               }
               if (ok && t) { memcpy(dists, tmp, sizeof(float) * (size_t)t); nd = t; }
            }
         }
      }
   }
   {  /* the most negative Rot.x is the floor pose (Rot.x < 0 under LocalCam) */
      int j;
      for (j = 0; j < np; j++)
         if (poses[j] <= -10.0f && (best < 0 || poses[j] < poses[best])) best = j;
   }
   if (best >= 0 && !prof->lc_pose_set)
   {
      prof->lc_pose_set = 1;
      prof->lc_rotx = poses[best];
      prof->lc_dist = (writes_dist && best < nd && dists[best] > 1.0f) ? dists[best] : 0.0f;
   }
}

/* does `function UpdateS()` set `shape.Enable = false` at the top
 * level of its body — i.e. on every call, whatever the frame? (Ice Hockey's
 * `___SelectWht`: the white highlight variants are hidden until another
 * script's LateUpdate re-enables them.) Block depth is counted from the
 * keywords that open a Lua block (`function if for while repeat` and a bare
 * `do`) and the ones that close it (`end until`); a `do` that belongs to a
 * `for`/`while` opens nothing new. Conditional writes are not evaluated. */
static int ra3d_lua_is_word(const char *s, size_t i, size_t e, const char *w, size_t wn)
{
   char c;
   if (i + wn > e || memcmp(s + i, w, wn)) return 0;
   if (i > 0) { c = s[i - 1]; if (c == '_' || c == '.' || c == ':' || (c >= '0' && c <= '9') ||
                                  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return 0; }
   if (i + wn < e) { c = s[i + wn]; if (c == '_' || (c >= '0' && c <= '9') ||
                                       (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) return 0; }
   return 1;
}

static int ra3d_lua_updates_hides(const char *s, size_t n)
{
   size_t i = 0;
   int depth = 0, fn_depth = -1, loop_pending = 0;
   static const char kEn[] = "shape.Enable";
   while (i < n)
   {
      size_t a = i, e, k;
      while (i < n && s[i] != '\n') i++;
      e = i++;
      for (k = a; k + 1 < e; k++)                          /* strip a comment */
         if (s[k] == '-' && s[k + 1] == '-') { e = k; break; }
      while (a < e && (s[a] == ' ' || s[a] == '\t')) a++;
      /* the statement test happens at the depth the line STARTS at */
      if (fn_depth >= 0 && depth == fn_depth + 1 &&
          e - a >= sizeof(kEn) - 1 && !memcmp(s + a, kEn, sizeof(kEn) - 1))
      {
         size_t q = a + sizeof(kEn) - 1;
         while (q < e && s[q] == ' ') q++;
         if (q + 1 < e && s[q] == '=' && s[q + 1] != '=')
         {
            q++;
            while (q < e && s[q] == ' ') q++;
            if (e - q >= 5 && !memcmp(s + q, "false", 5)) return 1;
         }
      }
      for (k = a; k < e; k++)
      {
         if (s[k] == '"' || s[k] == '\'')                 /* skip a string */
         {
            char qc = s[k++];
            while (k < e && s[k] != qc) { if (s[k] == '\\') k++; k++; }
            continue;
         }
         if (ra3d_lua_is_word(s, k, e, "function", 8))
         {
            size_t q = k + 8;
            while (q < e && s[q] == ' ') q++;
            if (fn_depth < 0 && depth == 0 && e - q >= 8 && !memcmp(s + q, "UpdateS(", 8))
               fn_depth = depth;
            depth++; k += 7;
         }
         else if (ra3d_lua_is_word(s, k, e, "if", 2) ||
                  ra3d_lua_is_word(s, k, e, "repeat", 6))
            depth++;
         else if (ra3d_lua_is_word(s, k, e, "for", 3) ||
                  ra3d_lua_is_word(s, k, e, "while", 5))
         { depth++; loop_pending = 1; }
         else if (ra3d_lua_is_word(s, k, e, "do", 2))
         { if (loop_pending) loop_pending = 0; else depth++; }
         else if (ra3d_lua_is_word(s, k, e, "end", 3) ||
                  ra3d_lua_is_word(s, k, e, "until", 5))
         {
            depth--;
            if (fn_depth >= 0 && depth == fn_depth) fn_depth = -2;   /* UpdateS closed */
         }
      }
      if (fn_depth == -2) fn_depth = -1;
   }
   return 0;
}

/* literal `Setting.EmptyTile = true|false` writes. */
static void ra3d_scrape_empty_tile(Ra3dProfile *prof, const char *s, size_t n)
{
   size_t i = 0;
   int in_start = 0;
   static const char kET[] = "Setting.EmptyTile";
   while (i < n)
   {
      size_t a = i, e, q;
      while (i < n && s[i] != '\n') i++;
      e = i++;
      while (a < e && (s[a] == ' ' || s[a] == '\t')) a++;
      if (e - a >= 9 && !memcmp(s + a, "function ", 9))
      {
         q = a + 9;
         while (q < e && s[q] == ' ') q++;
         in_start = (e - q >= 6 && !memcmp(s + q, "Start(", 6));
         continue;
      }
      if (e - a < sizeof(kET) - 1 || memcmp(s + a, kET, sizeof(kET) - 1)) continue;
      q = a + sizeof(kET) - 1;
      while (q < e && s[q] == ' ') q++;
      if (q + 1 >= e || s[q] != '=' || s[q + 1] == '=') continue;
      q++;
      while (q < e && s[q] == ' ') q++;
      {
         int val = (e - q >= 4 && !memcmp(s + q, "true", 4)) ? 1
                 : (e - q >= 5 && !memcmp(s + q, "false", 5)) ? 0 : -1;
         if (val < 0) continue;
         if (in_start) { if (prof->et_start < 0) prof->et_start = val; }
         else if (val) prof->et_dyn = 1;
      }
   }
}

/* Pattern3D.IsLinkableScript — the script's TagStr contains `*`, or
 * any of its ','-split, trimmed tags equals one of the pattern's. */
static int ra3d_tags_share(const char *a, size_t an, const char *b, size_t bn)
{
   size_t i = 0;
   while (i < an)
   {
      size_t s0 = i, s1;
      while (i < an && a[i] != ',') i++;
      s1 = i++;
      while (s0 < s1 && (a[s0] == ' ' || a[s0] == '\t')) s0++;
      while (s1 > s0 && (a[s1-1] == ' ' || a[s1-1] == '\t' || a[s1-1] == '\r' || a[s1-1] == '\n')) s1--;
      if (s1 > s0)
      {
         size_t j = 0;
         while (j < bn)
         {
            size_t t0 = j, t1;
            while (j < bn && b[j] != ',') j++;
            t1 = j++;
            while (t0 < t1 && (b[t0] == ' ' || b[t0] == '\t')) t0++;
            while (t1 > t0 && (b[t1-1] == ' ' || b[t1-1] == '\t' || b[t1-1] == '\r' || b[t1-1] == '\n')) t1--;
            if (t1 - t0 == s1 - s0 && !memcmp(a + s0, b + t0, s1 - s0)) return 1;
         }
      }
   }
   return 0;
}

/* Pattern3D field 19, the texture = { 1 w, 2 h,
 * 10: { 1: repeated int32 data, 2: format, 3: repeated int16
 * extra } }. Index (0): 16 pixels per int, 2 bits each,
 * plus one extra bit each in `extra` -> values 0-7. Direct (1): one ARGB
 * int per pixel. Repeated fields arrive unpacked (varints)
 * in the files seen; packed is accepted too. */
static int ra3d_tex_ints(const uint8_t *p, size_t n, uint32_t field, uint32_t *out, uint32_t cap)
{
   ra3d_rd r; uint32_t f, wt; uint64_t v; const uint8_t *pl; size_t pn;
   uint32_t c = 0;
   r.p = p; r.end = p + n;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
   {
      if (f != field) continue;
      if (wt == 0) { if (c < cap) out[c] = (uint32_t)v; c++; }
      else if (wt == 2)
      {
         const uint8_t *q = pl, *e = pl + pn;
         while (q < e)
         {
            uint64_t pv = 0; int sh = 0;
            while (q < e) { uint8_t b = *q++; pv |= (uint64_t)(b & 0x7F) << sh; sh += 7; if (!(b & 0x80)) break; }
            if (c < cap) out[c] = (uint32_t)pv;
            c++;
         }
      }
   }
   return (int)c;
}

static void ra3d_parse_tex(Ra3dProfile *prof, Ra3dShape3D *sh, const uint8_t *p, size_t n)
{
   ra3d_rd r; uint32_t f, wt; uint64_t v; const uint8_t *pl; size_t pn;
   uint32_t w = 0, h = 0, fmt = 0, i, npx, nint, *data = NULL, *extra = NULL;
   const uint8_t *td = NULL; size_t tdn = 0;
   uint8_t *px = NULL;
   r.p = p; r.end = p + n;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
   {
      if (f == 1 && wt == 0) w = (uint32_t)v;
      else if (f == 2 && wt == 0) h = (uint32_t)v;
      else if (f == 10 && wt == 2) { td = pl; tdn = pn; }
   }
   if (!td || !w || !h || w > 256 || h > 256 || (w & 7) || (h & 7)) return;
   r.p = td; r.end = td + tdn;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
      if (f == 2 && wt == 0) fmt = (uint32_t)v;
   if (fmt > 1) return;
   npx  = w * h;
   nint = fmt ? npx : (npx + 15) / 16;
   data  = (uint32_t *)calloc(nint, sizeof(uint32_t));
   extra = (uint32_t *)calloc(nint, sizeof(uint32_t));
   px    = (uint8_t *)malloc(npx);
   if (!data || !extra || !px) goto done;
   if ((uint32_t)ra3d_tex_ints(td, tdn, 1, data, nint) != nint) goto done;
   if (!fmt) ra3d_tex_ints(td, tdn, 3, extra, nint);   /* absent = all zero */
   if (fmt)
   {  /* Direct: the colours for the shader, presence for the mesher */
      uint32_t first = prof->dtex.n, e = sh->empty_color;
      uint8_t solid = (uint8_t)(e == 1 ? 2 : 1);
      for (i = 0; i < npx; i++)
      {
         if (!RA3D_PUSH(prof->dtex, data[i], sizeof(uint32_t))) { prof->dtex.n = first; goto done; }
         /* GetPixel(x,y) != emptyColor, on the ARGB int */
         px[i] = (data[i] == e) ? (uint8_t)e : solid;
      }
      sh->dtex_first = first; sh->dtex_w = (uint16_t)w; sh->dtex_h = (uint16_t)h;
   }
   else
      for (i = 0; i < npx; i++)
         px[i] = (uint8_t)(((data[i >> 4] >> ((i & 15) * 2)) & 3u)
                         | (((extra[i >> 4] >> (i & 15)) & 1u) << 2));
   {  /* as 8x8 tiles, row-major */
      uint32_t gw = w / 8, gh = h / 8, tx, ty, y, first = prof->ttiles.n / 64;
      if (!ra3d_grow((void **)&prof->ttiles.v, &prof->ttiles.cap,
                     prof->ttiles.n + gw * gh * 64, 1)) goto done;
      for (ty = 0; ty < gh; ty++)
         for (tx = 0; tx < gw; tx++)
            for (y = 0; y < 8; y++)
            {
               memcpy(prof->ttiles.v + prof->ttiles.n, px + (size_t)(ty * 8 + y) * w + tx * 8, 8);
               prof->ttiles.n += 8;
            }
      sh->tt_first = first; sh->tt_gw = (uint8_t)gw; sh->tt_gh = (uint8_t)gh;
   }
done:
   free(data); free(extra); free(px);
}

/* append (once per frame) ONE texture tile of a
 * shape — `cell` = gy*tt_gw + gx of its texture — to the frame's extra atlas;
 * returns its index there, or ~0. Per tile, not per texture: with partial
 * regions drawing textures, appending whole textures took Ice Hockey's
 * extra atlas from 80 to ~4000 tiles a frame. `tt_gen`/`tt_base` are indexed
 * by the profile-wide texture tile (sh->tt_first + cell). */
static uint32_t ra3d_frame_tt_tile(Ra3dGeoFrame *g, const Ra3dProfile *prof, uint32_t si, uint32_t cell)
{
   const Ra3dShape3D *sh;
   uint32_t nall, ti;
   if (!g || !prof || si >= prof->shapes.n) return 0xFFFFFFFFu;
   sh = &prof->shapes.v[si];
   if (!sh->tt_gw || cell >= (uint32_t)sh->tt_gw * sh->tt_gh) return 0xFFFFFFFFu;
   nall = prof->ttiles.n / 64;
   ti = sh->tt_first + cell;
   if (ti >= nall) return 0xFFFFFFFFu;
   if (g->tt_cap < nall)
   {
      uint32_t *a = (uint32_t *)calloc(nall, sizeof(uint32_t));
      uint32_t *b = (uint32_t *)calloc(nall, sizeof(uint32_t));
      if (!a || !b) { free(a); free(b); return 0xFFFFFFFFu; }
      free(g->tt_gen); free(g->tt_base);
      g->tt_gen = a; g->tt_base = b; g->tt_cap = nall;
   }
   if (g->tt_gen[ti] == g->tt_stamp) return g->tt_base[ti];
   if (!ra3d_grow((void **)&g->xpx, &g->xpx_cap, (g->xpx_n + 1) * 64, 1)) return 0xFFFFFFFFu;
   memcpy(g->xpx + (size_t)g->xpx_n * 64, prof->ttiles.v + (size_t)ti * 64, 64);
   g->tt_gen[ti] = g->tt_stamp; g->tt_base[ti] = g->xpx_n;
   return g->xpx_n++;
}

Ra3dProfile *ra3d_profile_parse(const void *data, size_t len,
                                char *err, size_t errlen)
{
   Ra3dProfile *prof = (Ra3dProfile*)calloc(1, sizeof(Ra3dProfile));
   static uint32_t s_ra3d_prof_serial = 0;
   ra3d_rd r;
   uint32_t f, wt; uint64_t v; const uint8_t *pl; size_t pn;
   int magic_ok = 0;

   if (!prof) return NULL;
   prof->serial = ++s_ra3d_prof_serial;
   if (!prof->serial) prof->serial = ++s_ra3d_prof_serial;
   prof->vhash_mask = (1u << 20) - 1u;    /* 1M slots, ~4 MB, sized for the
                                           * biggest official profile with
                                           * room to spare */
   prof->vhash = (uint32_t*)malloc((size_t)(prof->vhash_mask + 1) * sizeof(uint32_t));
   if (!prof->vhash) { free(prof); return NULL; }
   memset(prof->vhash, 0xFF, (size_t)(prof->vhash_mask + 1) * sizeof(uint32_t));

   {  /* 3dSen's default layer shadow flags */
      int li;
      for (li = 0; li < 6; li++)
      {
         prof->layer_cast[li] = (uint8_t)(li == 2);
         prof->layer_recv[li] = (uint8_t)(li >= 2);
      }
   }
   prof->lc_static = prof->lc_start = -1;
   prof->et_start = -1;                      /* (et_static: absent = false) */
   r.p = (const uint8_t*)data; r.end = r.p + len;
   while (ra3d_field(&r, &f, &wt, &v, &pl, &pn))
   {
      if (f == 1 && wt == 2 && pn == 3 && memcmp(pl, "3dn", 3) == 0) magic_ok = 1;
      /* 3 = Script { 4: Lua source } — scrape Start()'s literal
       * Setting.Layer[N].CastShadow / RecvShadow writes */
      if (f == 3 && wt == 2)
      {
         ra3d_rd sr; uint32_t sf, swt; uint64_t sv; const uint8_t *spl; size_t spn;
         int enabled = 0, hides = 0;
         const char *tg = NULL; size_t tgn = 0;
         sr.p = pl; sr.end = pl + pn;
         while (ra3d_field(&sr, &sf, &swt, &sv, &spl, &spn))
         {
            if (sf == 4 && swt == 2)
            {
               ra3d_scrape_layer_shadow(prof, (const char*)spl, spn);
               ra3d_scrape_localcam(prof, (const char*)spl, spn);
               hides = ra3d_lua_updates_hides((const char*)spl, spn);
               ra3d_scrape_empty_tile(prof, (const char*)spl, spn);
            }
            else if (sf == 2 && swt == 0) enabled = sv != 0;
            else if (sf == 6 && swt == 2) { tg = (const char*)spl; tgn = spn; }
         }
         {  /* keep the script itself for the Lua VM */
            ra3d_rd s2; uint32_t f2, w2; uint64_t v2; const uint8_t *p2; size_t n2;
            Ra3dScript sc; int en = 1;
            memset(&sc, 0, sizeof(sc));
            s2.p = pl; s2.end = pl + pn;
            while (ra3d_field(&s2, &f2, &w2, &v2, &p2, &n2))
            {
               uint32_t *off = NULL, *len = NULL; size_t q;
               if      (f2 == 1 && w2 == 2) { off = &sc.name_off; len = &sc.name_len; }
               else if (f2 == 4 && w2 == 2) { off = &sc.src_off;  len = &sc.src_len;  }
               else if (f2 == 6 && w2 == 2) { off = &sc.tag_off;  len = &sc.tag_len;  }
               else if (f2 == 2 && w2 == 0) en = v2 != 0;
               if (!off) continue;
               *off = prof->scriptpool.n; *len = (uint32_t)n2;
               for (q = 0; q < n2; q++) RA3D_PUSH(prof->scriptpool, (char)p2[q], 1);
               RA3D_PUSH(prof->scriptpool, (char)0, 1);
            }
            sc.enabled = (uint8_t)en;
            RA3D_PUSH(prof->scripts, sc, sizeof(Ra3dScript));
         }
         if (enabled && hides && tg && tgn)
         {  /* remember the hiding script's TagStr, NUL-terminated */
            size_t q;
            for (q = 0; q < tgn; q++) RA3D_PUSH(prof->hidetags, tg[q], 1);
            RA3D_PUSH(prof->hidetags, (char)0, 1);
            prof->hide_scripts++;
            if (memchr(tg, '*', tgn)) prof->hide_star++;
         }
         continue;
      }
      if (f == 8 && wt == 2 && pn < sizeof(prof->title))
      { memcpy(prof->title, pl, pn); prof->title[pn] = 0; }
      /* 6 = _Setting_ -> 1 = Light ->
       * { 1: direction {1 x, 2 y, 3 z: float}, 2: colour {1: int ARGB} }.
       * proto3-style omission means a missing component is 0. */
      if (f == 6 && wt == 2)
      {
         ra3d_rd sr; uint32_t sf, swt; uint64_t sv; const uint8_t *spl; size_t spn;
         sr.p = pl; sr.end = pl + pn;
         while (ra3d_field(&sr, &sf, &swt, &sv, &spl, &spn))
         {
            ra3d_rd lr; uint32_t lf, lwt; uint64_t lv; const uint8_t *lpl; size_t lpn;
            /* 24 = bool EmptyTile */
            if (sf == 24 && swt == 0) { prof->et_static = sv ? 1 : 0; continue; }
            /* 25 = bool LocalCam */
            if (sf == 25 && swt == 0) { prof->lc_static = sv ? 1 : 0; continue; }
            /* the matcher's own settings — 18 SameBgPalette,
             * 37 SameSpPalette, 19 SpriteTolerance, 20 scan direction */
            if (sf == 18 && swt == 0) { prof->same_bg_pal = sv ? 1 : 0; continue; }
            if (sf == 37 && swt == 0) { prof->same_sp_pal = sv ? 1 : 0; continue; }
            if (sf == 19 && swt == 0) { prof->sp_tol = (int32_t)(uint32_t)sv; continue; }
            if (sf == 20 && swt == 0) { prof->scan_dir = (int32_t)(uint32_t)sv; continue; }
            /* 6 = LayerConfig { 1: repeated LayerP { 1 Offset: float,
             * 2 Aligned: varint } } in layer order (UNIDENTIFIED, UI, L1..L4) */
            if (sf == 6 && swt == 2)
            {
               ra3d_rd yr; uint32_t yf, ywt; uint64_t yv; const uint8_t *ypl; size_t ypn;
               int li = 0;
               yr.p = spl; yr.end = spl + spn;
               while (ra3d_field(&yr, &yf, &ywt, &yv, &ypl, &ypn))
               {
                  ra3d_rd pr; uint32_t pf, pwt; uint64_t pv; const uint8_t *ppl; size_t ppn;
                  if (yf != 1 || ywt != 2) continue;
                  if (li >= 6) break;
                  prof->layer_off[li] = 0.0f; prof->layer_align[li] = 0;
                  pr.p = ypl; pr.end = ypl + ypn;
                  while (ra3d_field(&pr, &pf, &pwt, &pv, &ppl, &ppn))
                  {
                     if (pf == 1 && pwt == 5) prof->layer_off[li] = ra3d_f32(pv);
                     else if (pf == 2 && pwt == 0) prof->layer_align[li] = (uint8_t)(pv <= 2 ? pv : 0);
                  }
                  li++;
               }
               if (li >= 6) prof->layer_set = 1;
               continue;
            }
            /* 4 = Clipping { 1 x, 2 y, 3 z, 4 w: float } */
            if (sf == 4 && swt == 2)
            {
               ra3d_rd cr; uint32_t cf, cwt; uint64_t cv; const uint8_t *cpl; size_t cpn;
               prof->clip[0] = prof->clip[1] = prof->clip[2] = prof->clip[3] = 0.0f;
               cr.p = spl; cr.end = spl + spn;
               while (ra3d_field(&cr, &cf, &cwt, &cv, &cpl, &cpn))
                  if (cwt == 5 && cf >= 1 && cf <= 4) prof->clip[cf - 1] = ra3d_f32(cv);
               prof->clip_set = 1;
               continue;
            }
            if (sf != 1 || swt != 2) continue;
            lr.p = spl; lr.end = spl + spn;
            while (ra3d_field(&lr, &lf, &lwt, &lv, &lpl, &lpn))
            {
               if (lf == 1 && lwt == 2)
               {
                  ra3d_vec3(lpl, lpn, prof->light_dir, 0.0f);
                  prof->light_flags |= 1;
               }
               else if (lf == 2 && lwt == 2)
               {
                  ra3d_rd cr; uint32_t cf, cwt; uint64_t cv; const uint8_t *cpl; size_t cpn;
                  uint32_t argb = 0;
                  cr.p = lpl; cr.end = lpl + lpn;
                  while (ra3d_field(&cr, &cf, &cwt, &cv, &cpl, &cpn))
                     if (cf == 1 && cwt == 0) argb = (uint32_t)cv;
                  prof->light_col[0] = (float)((argb >> 16) & 0xFF) / 255.0f;
                  prof->light_col[1] = (float)((argb >>  8) & 0xFF) / 255.0f;
                  prof->light_col[2] = (float)( argb        & 0xFF) / 255.0f;
                  prof->light_flags |= 2;
               }
            }
         }
         continue;
      }
      if (f != 4 || wt != 2) continue;

      /* ---- Pattern { 2: id, 10: PatternBody } ---- */
      {
         ra3d_rd pr; uint32_t pf, pwt; uint64_t pv; const uint8_t *ppl; size_t ppn;
         uint32_t pid = 0;
         const uint8_t *body = NULL; size_t bodyn = 0;
         pr.p = pl; pr.end = pl + pn;
         while (ra3d_field(&pr, &pf, &pwt, &pv, &ppl, &ppn))
         {
            if (pf == 2 && pwt == 0) pid = (uint32_t)pv;
            else if (pf == 10 && pwt == 2) { body = ppl; bodyn = ppn; }
         }
         if (!body) continue;

         {
            ra3d_rd br; uint32_t bf, bwt; uint64_t bv; const uint8_t *bpl; size_t bpn;
            Ra3dPattern pat;
            uint32_t grid_index = 0;
            uint32_t cw = 99, ch = 99, tw = 0, th = 0;
            uint32_t self_conn = 1, skip_geo = 0;
            uint32_t cell_first = prof->cells.n;
            uint32_t shape_first = prof->shapes.n;
            uint32_t ident_first = prof->idents.n;
            uint32_t link_first = prof->links.n;
            /* the grid arrives BEFORE t_size in file order, so every entry —
             * wildcards included — is collected into prof->gtmp and shaped once
             * t_size is known. */
            prof->gtmp.n = 0;

            br.p = body; br.end = body + bodyn;
            while (ra3d_field(&br, &bf, &bwt, &bv, &bpl, &bpn))
            {
               if (bf == 1 && bwt == 3)
               {
                  /* one grid cell: empty group = wildcard, else the group's
                   * field 1 is the Tile2D message */
                  ra3d_rd gr; uint32_t gf, gwt; uint64_t gv;
                  const uint8_t *gpl; size_t gpn;
                  const uint8_t *t2d = NULL; size_t t2dn = 0;
                  gr.p = bpl; gr.end = bpl + bpn;
                  while (ra3d_field(&gr, &gf, &gwt, &gv, &gpl, &gpn))
                     if (gf == 1 && gwt == 2) { t2d = gpl; t2dn = gpn; }
                  grid_index++;
                  {  /* every grid index gets a gtmp slot; var_count 0 = wildcard */
                     Ra3dPatCell w0;
                     w0.gx = (uint16_t)(grid_index - 1); w0.gy = 0;
                     w0.var_first = 0; w0.var_count = 0;
                     if (!RA3D_PUSH(prof->gtmp, w0, sizeof(Ra3dPatCell))) break;
                  }
                  if (!t2d) continue;                      /* wildcard */
                  {
                     ra3d_rd tr; uint32_t tf, twt; uint64_t tv;
                     const uint8_t *tpl; size_t tpn;
                     uint64_t def_id = 0; int have_def = 0;
                     const uint8_t *vlist = NULL; size_t vlistn = 0;
                     uint64_t ref_id = 0; int have_ref = 0;
                     tr.p = t2d; tr.end = t2d + t2dn;
                     while (ra3d_field(&tr, &tf, &twt, &tv, &tpl, &tpn))
                     {
                        if      (tf == 2  && twt == 0) { def_id = tv; have_def = 1; }
                        else if (tf == 10 && twt == 2) { vlist = tpl; vlistn = tpn; }
                        else if (tf == 1  && twt == 0) { ref_id = tv; have_ref = 1; }
                     }
                     {
                        Ra3dPatCell c;
                        c.gx = (uint16_t)(grid_index - 1);   /* linear for now */
                        c.gy = 0;
                        c.var_first = 0; c.var_count = 0;
                        if (vlist)
                        {
                           uint16_t n2;
                           c.var_first = ra3d_parse_variants(prof, vlist, vlistn, &n2);
                           c.var_count = n2;
                           if (have_def) ra3d_t2d_set(prof, (uint32_t)def_id,
                                                      c.var_first, n2);
                        }
                        else if (have_ref && ref_id < prof->t2d_cap &&
                                 prof->t2d_count[ref_id])
                        {
                           c.var_first = prof->t2d_first[ref_id];
                           c.var_count = prof->t2d_count[ref_id];
                        }
                        else continue;                      /* unresolved -> wildcard */
                        if (!c.var_count) continue;
                        /* a blank (all-zero) cell is a REAL identity, as in
                         * 3dSen (it is in Pattern.tiles2D and in the links). It
                         * only ever matches when Setting.EmptyTile puts blank
                         * frame tiles into the matcher; with EmptyTile off the
                         * frame has none, which is exactly the old wildcard. */
                        prof->gtmp.v[prof->gtmp.n - 1] = c;
                     }
                  }
               }
               else if (bf == 2 && bwt == 2)
               {
                  ra3d_rd sr; uint32_t sf, swt; uint64_t sv;
                  const uint8_t *spl; size_t spn;
                  sr.p = bpl; sr.end = bpl + bpn;
                  while (ra3d_field(&sr, &sf, &swt, &sv, &spl, &spn))
                  { if (sf == 1 && swt == 0) cw = (uint32_t)sv;
                    else if (sf == 2 && swt == 0) ch = (uint32_t)sv; }
               }
               else if (bf == 3 && bwt == 2)
               {
                  ra3d_rd sr; uint32_t sf, swt; uint64_t sv;
                  const uint8_t *spl; size_t spn;
                  sr.p = bpl; sr.end = bpl + bpn;
                  while (ra3d_field(&sr, &sf, &swt, &sv, &spl, &spn))
                  { if (sf == 1 && swt == 0) tw = (uint32_t)sv;
                    else if (sf == 2 && swt == 0) th = (uint32_t)sv; }
               }
               else if (bf == 11 && bwt == 0) self_conn = (uint32_t)bv;
               else if (bf == 12 && bwt == 0) skip_geo = (uint32_t)bv;
               else if (bf == 10 && bwt == 2)
               {
                  /* Pattern3D { 1|2: id, 10: Shape3DParams } */
                  ra3d_rd sr; uint32_t sf, swt; uint64_t sv;
                  const uint8_t *spl; size_t spn;
                  const uint8_t *par = NULL; size_t parn = 0;
                  sr.p = bpl; sr.end = bpl + bpn;
                  while (ra3d_field(&sr, &sf, &swt, &sv, &spl, &spn))
                     if (sf == 10 && swt == 2) { par = spl; parn = spn; }
                  if (par)
                  {
                     ra3d_rd qr; uint32_t qf, qwt; uint64_t qv;
                     const uint8_t *qpl; size_t qpn;
                     Ra3dShape3D sh;
                     const uint8_t *tex_pl = NULL; size_t tex_pn = 0;
                     memset(&sh, 0, sizeof(sh));
                     sh.size_z = 0.0f; sh.geo = 0; sh.layer = 2 /* L1 */;
                     sh.scale[0] = sh.scale[1] = sh.scale[2] = 1.0f;
                     sh.pivot[0] = sh.pivot[1] = sh.pivot[2] = 0.5f;
                     sh.alpha = 1.0f;
                     sh.render_style = 1;   /* always serialised; 1 if absent */
                     qr.p = par; qr.end = par + parn;
                     while (ra3d_field(&qr, &qf, &qwt, &qv, &qpl, &qpn))
                     {
                        switch (qf)
                        {
                           case 1:  if (qwt == 0) sh.size_z = (float)qv; break;
                           case 2:  if (qwt == 0) sh.geo = (uint8_t)(qv < 6 ? qv : 0); break;
                           case 7:  if (qwt == 0) sh.layer = (uint8_t)(qv < 6 ? qv : 2); break;
                           case 8:  if (qwt == 2) ra3d_vec3(qpl, qpn, sh.scale, 1.0f); break;
                           case 9:  if (qwt == 2) ra3d_vec3(qpl, qpn, sh.rot, 0.0f); break;
                           case 10: if (qwt == 2) ra3d_vec3(qpl, qpn, sh.offset, 0.0f); break;
                           case 11: if (qwt == 2) ra3d_vec3(qpl, qpn, sh.pivot, 0.5f); break;
                           case 12: if (qwt == 5) sh.alpha = ra3d_f32(qv); break;
                           /* renderStyle and the shadow tags */
                           case 18: if (qwt == 0) sh.render_style = (uint8_t)(qv <= 2 ? qv : 1); break;
                           case 13: if (qwt == 0) sh.render_mode = (uint8_t)(qv <= 3 ? qv : 0); break;
                           case 16: case 17:   /* PMatrix4x4 row 3 -> CData */
                                    if (qwt == 2)
                                    {
                                       ra3d_rd mr; uint32_t mf, mwt; uint64_t mv;
                                       const uint8_t *mpl; size_t mpn;
                                       mr.p = qpl; mr.end = qpl + qpn;
                                       while (ra3d_field(&mr, &mf, &mwt, &mv, &mpl, &mpn))
                                          if (mwt == 5 && mf >= 13 && mf <= 16)
                                             sh.cdata[(qf == 16 ? 0 : 4) + (mf - 13)] = ra3d_f32(mv);
                                    }
                                    break;
                           case 20: if (qwt == 2)
                                    {
                                       size_t q;
                                       ra3d_shadow_tags(&sh, (const char*)qpl, qpn);
                                       sh.tag_off = prof->tagpool.n;
                                       sh.tag_len = (uint16_t)(qpn < 65535 ? qpn : 65535);
                                       for (q = 0; q < sh.tag_len; q++)
                                          RA3D_PUSH(prof->tagpool, (char)qpl[q], 1);
                                    }
                                    break;
                           /* the voxel fill's inputs */
                           case 3:  if (qwt == 0 && qv) sh.fill_flags |= RA3D_INST_ANTISHADOW; break;
                           case 4:  if (qwt == 0 && qv) sh.fill_flags |= RA3D_INST_FLIP; break;
                           case 5:  if (qwt == 0 && qv) sh.fill_flags |= RA3D_INST_SOLID; break;
                           case 6:  if (qwt == 0 && qv) sh.fill_flags |= RA3D_INST_FULLWARP; break;
                           case 19: if (qwt == 2) { tex_pl = qpl; tex_pn = qpn; } break;   /* after the loop */
                           case 23: if (qwt == 0)
                                    {  /* sbyte as a plain varint; <0 -> +5, as 3dSen reads it */
                                       int64_t e = (int64_t)(int32_t)(uint32_t)qv;
                                       if (e < 0) e += 5;
                                       sh.empty_color = (uint8_t)((e >= 0 && e <= 4) ? e : 0);
                                    }
                                    break;
                           default: break;
                        }
                     }
                     if (tex_pl) ra3d_parse_tex(prof, &sh, tex_pl, tex_pn);
                     sh.pattern = prof->patterns.n;   /* this pattern, once pushed */
                     sh.index = (uint8_t)((prof->shapes.n - shape_first) < 255
                                          ? (prof->shapes.n - shape_first) : 255);
                     RA3D_PUSH(prof->shapes, sh, sizeof(Ra3dShape3D));
                  }
               }
            }

            /* prep_patterns' rejections, verbatim */
            if (tw == 0 || th == 0 || grid_index != tw * th ||
                prof->gtmp.n != tw * th)
            {
               prof->cells.n  = cell_first;
               prof->shapes.n = shape_first;
               continue;
            }
            /* ---- the constrained cells, with (gx, gy) row-major ---- */
            {
               uint32_t i;
               for (i = 0; i < prof->gtmp.n; i++)
               {
                  Ra3dPatCell c = prof->gtmp.v[i];
                  if (!c.var_count) continue;
                  c.gx = (uint16_t)(i % tw);
                  c.gy = (uint16_t)(i / tw);
                  if (!RA3D_PUSH(prof->cells, c, sizeof(Ra3dPatCell))) break;
               }
            }
            /* ---- Pattern.CreateLinks: right and down, wrapping when
             * selfConnected. A cell may in principle hold more than one variant
             * (always exactly one in the 101 official profiles), so every pair
             * is linked. ---- */
            {
               uint32_t i, j, a, b;
               for (j = 0; j < th; j++)
                  for (i = 0; i < tw; i++)
                  {
                     const Ra3dPatCell *ca = &prof->gtmp.v[j * tw + i];
                     if (!ca->var_count) continue;
                     if (self_conn || i + 1 < tw)
                     {
                        const Ra3dPatCell *cb =
                           &prof->gtmp.v[j * tw + (i + 1) % tw];
                        for (a = 0; a < ca->var_count; a++)
                           for (b = 0; b < cb->var_count; b++)
                           {
                              Ra3dLink lk;
                              lk.p  = prof->patterns.n;
                              lk.a  = prof->cellvars.v[ca->var_first + a];
                              lk.bd = prof->cellvars.v[cb->var_first + b];
                              RA3D_PUSH(prof->links, lk, sizeof(Ra3dLink));
                           }
                     }
                     if (self_conn || j + 1 < th)
                     {
                        const Ra3dPatCell *cb =
                           &prof->gtmp.v[((j + 1) % th) * tw + i];
                        for (a = 0; a < ca->var_count; a++)
                           for (b = 0; b < cb->var_count; b++)
                           {
                              Ra3dLink lk;
                              lk.p  = prof->patterns.n;
                              lk.a  = prof->cellvars.v[ca->var_first + a];
                              lk.bd = prof->cellvars.v[cb->var_first + b]
                                    | 0x80000000u;
                              RA3D_PUSH(prof->links, lk, sizeof(Ra3dLink));
                           }
                     }
                  }
            }
            /* ---- Pattern.tiles2D: the distinct identities, sorted ---- */
            {
               uint32_t i, a, n;
               for (i = 0; i < prof->gtmp.n; i++)
               {
                  const Ra3dPatCell *c = &prof->gtmp.v[i];
                  for (a = 0; a < c->var_count; a++)
                  {
                     uint32_t v2 = prof->cellvars.v[c->var_first + a];
                     RA3D_PUSH(prof->idents, v2, sizeof(uint32_t));
                  }
               }
               n = prof->idents.n - ident_first;
               if (n > 1)
               {
                  uint32_t *base = prof->idents.v + ident_first, x, y, w2;
                  for (x = 1; x < n; x++)          /* insertion sort: n is small */
                  { w2 = base[x]; y = x;
                    while (y && base[y - 1] > w2) { base[y] = base[y - 1]; y--; }
                    base[y] = w2; }
                  for (x = 1, y = 1; x < n; x++)
                     if (base[x] != base[y - 1]) base[y++] = base[x];
                  prof->idents.n = ident_first + y;
               }
               /* each identity's last cell */
               if (ra3d_grow((void **)&prof->identcell.v, &prof->identcell.cap,
                             prof->idents.n ? prof->idents.n : 1, sizeof(uint32_t)))
               {
                  uint32_t q;
                  for (q = ident_first; q < prof->idents.n; q++) prof->identcell.v[q] = 0xFFFFFFFFu;
                  prof->identcell.n = prof->idents.n;
                  for (i = 0; i < prof->gtmp.n; i++)
                  {
                     const Ra3dPatCell *c = &prof->gtmp.v[i];
                     for (a = 0; a < c->var_count; a++)
                     {
                        uint32_t v2 = prof->cellvars.v[c->var_first + a];
                        uint32_t lo = ident_first, hi = prof->idents.n;
                        while (lo < hi)
                        {
                           uint32_t mid = lo + ((hi - lo) >> 1);
                           if (prof->idents.v[mid] < v2) lo = mid + 1; else hi = mid;
                        }
                        if (lo < prof->idents.n && prof->idents.v[lo] == v2)
                           prof->identcell.v[lo] = i;
                     }
                  }
               }
            }
            if (prof->cells.n == cell_first ||
                prof->idents.n == ident_first)
            {
               prof->cells.n  = cell_first;
               prof->shapes.n = shape_first;
               prof->idents.n = ident_first;
               prof->links.n  = link_first;
               continue;
            }
            pat.id = pid;
            pat.w = (uint16_t)tw; pat.h = (uint16_t)th;
            pat.cell_first = cell_first;
            pat.cell_count = prof->cells.n - cell_first;
            pat.cw = (uint16_t)(cw ? cw : 99);
            pat.ch = (uint16_t)(ch ? ch : 99);
            pat.skip_geo = (uint8_t)(skip_geo ? 1 : 0);
            pat.ident_first = ident_first;
            pat.ident_count = prof->idents.n - ident_first;
            pat.shape_first = shape_first;
            pat.shape_count = prof->shapes.n - shape_first;
            if (pat.cell_count > prof->max_cells) prof->max_cells = pat.cell_count;
            RA3D_PUSH(prof->patterns, pat, sizeof(Ra3dPattern));
         }
      }
   }

   if (!magic_ok)
   {
      if (err && errlen) snprintf(err, errlen, "not a .3dn (no 3dn magic)");
      ra3d_profile_free(prof);
      return NULL;
   }
   if (prof->patterns.n == 0)
   {
      if (err && errlen) snprintf(err, errlen, "no usable patterns");
      ra3d_profile_free(prof);
      return NULL;
   }

   /* link every Pattern3D to the scripts that hide it unconditionally
    * (Pattern3D.IsLinkableScript: `*` in the script's TagStr, or a shared tag) */
   if (prof->hide_scripts)
   {
      uint32_t i;
      for (i = 0; i < prof->shapes.n; i++)
      {
         Ra3dShape3D *sh = &prof->shapes.v[i];
         size_t o = 0;
         while (o < prof->hidetags.n)
         {
            const char *t = prof->hidetags.v + o;
            size_t tn = strlen(t);
            if (memchr(t, '*', tn) ||
                (sh->tag_len && ra3d_tags_share(t, tn, prof->tagpool.v + sh->tag_off,
                                                sh->tag_len)))
            { sh->lua_hidden = 1; prof->lua_hidden++; break; }
            o += tn + 1;
         }
      }
   }

   /* ---- index 1: the adjacency table, hashed. Sorting first is only to make
    * the dedupe cheap; the hash is what the matcher probes. ---- */
   if (prof->links.n)
   {
      uint32_t n = prof->links.n, i, w2, cap;
      qsort(prof->links.v, n, sizeof(Ra3dLink), ra3d_link_cmp);
      for (i = 1, w2 = 1; i < n; i++)
      {
         const Ra3dLink *a = &prof->links.v[w2 - 1], *b = &prof->links.v[i];
         if (a->p != b->p || a->a != b->a || a->bd != b->bd)
            prof->links.v[w2++] = *b;
      }
      prof->links.n = n = w2;
      cap = 64; while (cap < n * 2) cap <<= 1;
      prof->lhash_mask = cap - 1;
      prof->lhash = (uint32_t*)malloc((size_t)cap * sizeof(uint32_t));
      if (!prof->lhash) { ra3d_profile_free(prof); return NULL; }
      memset(prof->lhash, 0xFF, (size_t)cap * sizeof(uint32_t));
      for (i = 0; i < n; i++)
      {
         uint32_t h = ra3d_link_hash(prof->links.v[i].p, prof->links.v[i].a,
                                     prof->links.v[i].bd) & prof->lhash_mask;
         while (prof->lhash[h] != 0xFFFFFFFFu) h = (h + 1) & prof->lhash_mask;
         prof->lhash[h] = i;
      }
   }

   /* ---- index 2: Tile2D.patternSet, as CSR over variant id ---- */
   {
      uint32_t nv = prof->vars.n, p, i, run;
      prof->keypat_off = (uint32_t*)calloc(nv + 2, sizeof(uint32_t));
      if (!prof->keypat_off) { ra3d_profile_free(prof); return NULL; }
      for (p = 0; p < prof->patterns.n; p++)
      {
         const Ra3dPattern *pa = &prof->patterns.v[p];
         for (i = 0; i < pa->ident_count; i++)
            prof->keypat_off[prof->idents.v[pa->ident_first + i] + 1]++;
      }
      for (i = 0; i < nv; i++)
      {
         if (prof->keypat_off[i + 1] > prof->max_cands)
            prof->max_cands = prof->keypat_off[i + 1];
         prof->keypat_off[i + 1] += prof->keypat_off[i];
      }
      run = prof->keypat_off[nv];
      if (!ra3d_grow((void**)&prof->keypat.v, &prof->keypat.cap,
                     run ? run : 1, sizeof(uint32_t)))
      { ra3d_profile_free(prof); return NULL; }
      prof->keypat.n = run;
      {  /* a second cursor array, so the CSR fills in ascending pattern order */
         uint32_t *cur = (uint32_t*)malloc((size_t)(nv + 1) * sizeof(uint32_t));
         if (!cur) { ra3d_profile_free(prof); return NULL; }
         memcpy(cur, prof->keypat_off, (size_t)(nv + 1) * sizeof(uint32_t));
         for (p = 0; p < prof->patterns.n; p++)
         {
            const Ra3dPattern *pa = &prof->patterns.v[p];
            for (i = 0; i < pa->ident_count; i++)
               prof->keypat.v[cur[prof->idents.v[pa->ident_first + i]]++] = p;
         }
         free(cur);
      }
   }
   return prof;
}

void ra3d_profile_free(Ra3dProfile *p)
{
   if (!p) return;
   free(p->vars.v); free(p->cellvars.v); free(p->cells.v);
   free(p->shapes.v); free(p->patterns.v);
   free(p->links.v); free(p->lhash); free(p->idents.v); free(p->identcell.v);
   free(p->keypat.v); free(p->keypat_off); free(p->gtmp.v);
   free(p->vhash); free(p->t2d_first); free(p->t2d_count);
   free(p->tagpool.v); free(p->hidetags.v);
   free(p->scripts.v); free(p->scriptpool.v);
   free(p->dtex.v); free(p->ttiles.v);
   free(p);
}

uint32_t ra3d_profile_pattern_count(const Ra3dProfile *p) { return p ? p->patterns.n : 0; }
uint32_t ra3d_profile_shape_count  (const Ra3dProfile *p) { return p ? p->shapes.n   : 0; }
uint32_t ra3d_profile_variant_count(const Ra3dProfile *p) { return p ? p->vars.n     : 0; }
int ra3d_profile_light(const Ra3dProfile *p, float dir[3], float col[3])
{
   if (!p) return 0;
   memcpy(dir, p->light_dir, sizeof(float) * 3);
   memcpy(col, p->light_col, sizeof(float) * 3);
   return p->light_flags;
}

int ra3d_profile_layer_shadow(const Ra3dProfile *p, uint8_t cast[6], uint8_t recv[6])
{
   int i;
   if (!p)
   {
      for (i = 0; i < 6; i++) { cast[i] = (uint8_t)(i == 2); recv[i] = (uint8_t)(i >= 2); }
      return 0;
   }
   memcpy(cast, p->layer_cast, 6);
   memcpy(recv, p->layer_recv, 6);
   return p->layer_lua;
}

int ra3d_profile_localcam(const Ra3dProfile *p, float *rotx, float *dist)
{
   int on = 0, src = 0;
   if (rotx) *rotx = 0.0f;
   if (dist) *dist = 0.0f;
   if (!p) return 0;
   if (p->lc_updates)          { on = 1; src = 8; }
   else if (p->lc_start >= 0)  { on = p->lc_start; src = 4; }
   /* a scene-gated write overrides the static value at the first scene
    * evaluation (3dSen deep-copies _Setting_ at load, then the script runs) */
   else if (p->lc_scene)       { on = p->lc_pose_set; src = 16; }
   else if (p->lc_static > 0)  { on = 1; src = 2; }
   if (p->lc_pose_set)
   {
      if (rotx) *rotx = p->lc_rotx;
      if (dist) *dist = p->lc_dist;
   }
   return on ? (1 | src) : src;
}

float ra3d_layer_centre_z(const Ra3dProfile *p, const Ra3dKnobs *k, int layer, float d)
{
   int rl = (layer == 0 || layer > 5) ? 2 : layer;
   if (p && k && k->profile_layers && p->layer_set && rl != 1)
   {  /* 3dSen box [Offset + d/2(coef-1), Offset + d/2(coef+1)] -> centre
       * Offset + d/2*coef, negated into NES world */
      static const float coef[3] = { 1.0f, 0.0f, -1.0f };
      return -(p->layer_off[rl] + 0.5f * d * coef[p->layer_align[rl] % 3]);
   }
   return k ? k->layer_z[layer >= 0 && layer < 6 ? layer : 2] : 0.0f;
}

int ra3d_profile_empty_tile(const Ra3dProfile *p)
{
   if (!p) return 0;
   if (p->et_start >= 0) return p->et_start;
   if (p->et_dyn)        return 1;
   return p->et_static > 0;
}

int ra3d_profile_shape_cdata(const Ra3dProfile *p, uint32_t shape, float out[8])
{
   if (!p || shape >= p->shapes.n) { memset(out, 0, sizeof(float) * 8); return 0; }
   memcpy(out, p->shapes.v[shape].cdata, sizeof(float) * 8);
   return 1;
}

int ra3d_profile_clipping(const Ra3dProfile *p, float clip[4])
{
   if (!p || !p->clip_set) return 0;
   memcpy(clip, p->clip, sizeof(float) * 4);
   return 1;
}

/* ------------------------------------------------------------------- knobs */

void ra3d_knobs_defaults(Ra3dKnobs *k)
{
   /* our four invented constants, exactly as the Python prototype chose them. */
   k->size_z_scale    = 1.0f;      /* SizeZ read as pixels                    */
   k->layer_z[0]      = 0.0f;      /* UNIDENTIFIED                            */
   k->layer_z[1]      = 64.0f;     /* UI floats clearly in front              */
   k->layer_z[2]      = 0.0f;      /* L1 sits ON the panel                    */
   k->layer_z[3]      = -24.0f;    /* L2                                      */
   k->layer_z[4]      = -48.0f;    /* L3                                      */
   k->layer_z[5]      = -72.0f;    /* L4                                      */
   k->fallback_size_z = 8.0f;      /* today's shipped depth-plane look        */
   k->pattern3d_index = -1;        /* every variant, as 3dSen          */
   k->clip_ratio      = 0.0f;
   k->min_clip_cells  = 2;
   k->probes          = 4;
   k->enable_fallback = 1;
   k->flat_shapes     = -1;        /* auto: authored rotations unless an
                                    * un-engaged LocalCam floor (case)  */
   k->localcam_active = -1;
   k->unity_frame     = 1;
   k->empty_tile      = -1;        /* the profile's own */
   k->lua             = 1;
   k->lua_active      = 0;
   k->lua_localcam    = 0;
   k->profile_layers  = 1;
   k->grid_match      = 1;
   k->cull_set        = 0;
   k->nes_palette     = 1;
   k->retina          = 0;         /* v2's default, GREEDY */
   k->tile_share      = 1;         /* 3dSen's Tile3D sharing */
}

static int ra3d_cfg_num(const char *s, double *out)
{
   char *e = NULL;
   double d = strtod(s, &e);
   if (e == s) return 0;
   *out = d;
   return 1;
}

static const char *const RA3D_LEGACY_KEYS[] = {
   "flat_shapes", "plane_mode", "depth_scale", "size_z_scale",
   "layer_z_ui", "layer_z_l1", "layer_z_l2", "layer_z_l3", "layer_z_l4",
   "layer_z_unknown", "fallback_size_z", "fallback", "pattern3d_index",
   "clip_ratio", "min_clip_cells", "probes"
};
#define RA3D_LEGACY_KEY_COUNT (sizeof(RA3D_LEGACY_KEYS) / sizeof(RA3D_LEGACY_KEYS[0]))

static int ra3d_knobs_legacy_index(const char *key)
{
   unsigned i;
   for (i = 0; i < RA3D_LEGACY_KEY_COUNT; i++)
      if (!strcmp(key, RA3D_LEGACY_KEYS[i])) return (int)i;
   return -1;
}

int ra3d_knobs_is_legacy(const char *key)
{
   return key && ra3d_knobs_legacy_index(key) >= 0;
}

void ra3d_knobs_parse(Ra3dKnobs *k, const char *text, size_t len, int *unknown)
{
   ra3d_knobs_parse_ex(k, text, len, unknown, NULL, NULL);
}

void ra3d_knobs_parse_ex(Ra3dKnobs *k, const char *text, size_t len, int *unknown,
                         void (*legacy)(const char *key, void *ud), void *ud)
{
   const char *p = text, *end = text + len;
   uint32_t legacy_seen = 0;
   if (unknown) *unknown = 0;
   while (p < end)
   {
      const char *ls = p, *le;
      char key[64], val[64];
      size_t kn = 0, vn = 0;
      const char *eq;
      while (p < end && *p != '\n') p++;
      le = p;
      if (p < end) p++;
      while (ls < le && (*ls == ' ' || *ls == '\t')) ls++;
      if (ls >= le || *ls == '#' || *ls == ';') continue;
      eq = ls;
      while (eq < le && *eq != '=') eq++;
      if (eq >= le) continue;
      { const char *q = eq;
        while (q > ls && (q[-1] == ' ' || q[-1] == '\t')) q--;
        kn = (size_t)(q - ls); if (kn >= sizeof(key)) kn = sizeof(key) - 1;
        memcpy(key, ls, kn); key[kn] = 0; }
      { const char *q = eq + 1, *r2 = le;
        while (q < r2 && (*q == ' ' || *q == '\t' || *q == '"')) q++;
        while (r2 > q && (r2[-1] == ' ' || r2[-1] == '\t' || r2[-1] == '\r'
                          || r2[-1] == '"')) r2--;
        vn = (size_t)(r2 - q); if (vn >= sizeof(val)) vn = sizeof(val) - 1;
        memcpy(val, q, vn); val[vn] = 0; }
      {
         double d;
         int li = ra3d_knobs_legacy_index(key);
         if (li >= 0)
         {  /* a earlier key; the compiled default stands */
            if (!(legacy_seen & (1u << li)))
            {
               legacy_seen |= 1u << li;
               if (legacy) legacy(key, ud);
            }
            continue;
         }
         if (!ra3d_cfg_num(val, &d)) { if (unknown) (*unknown)++; continue; }
         if      (!strcmp(key, "unity_frame"))     k->unity_frame     = (int)d;
         else if (!strcmp(key, "empty_tile"))      k->empty_tile      = (int)d;
         else if (!strcmp(key, "lua"))             k->lua             = (int)d;
         else if (!strcmp(key, "profile_layers"))  k->profile_layers  = (int)d;
         else if (!strcmp(key, "grid_match"))      k->grid_match      = (int)d;
         else if (!strcmp(key, "nes_palette"))     k->nes_palette     = (int)d;
         else if (!strcmp(key, "retina"))          k->retina          = (int)d;
         else if (!strcmp(key, "tile_share"))      k->tile_share      = (int)d;
         else if (!strcmp(key, "lua_budget") || !strcmp(key, "lua_log")) { }
         /* Renderer-side knobs: valid keys, read by the shell rather than the
          * matcher, so they must not be counted as typos. */
         else if (!strcmp(key, "shadows") || !strcmp(key, "shadow_strength")
                  || !strcmp(key, "shadow_map_size")
                  /* profile selection, RAVisionLayers.m */
                  || !strcmp(key, "profile_match_min")
                  || !strcmp(key, "prefer_user_profiles")
                  || !strcmp(key, "bundled_profiles")) { }
         else if (unknown) (*unknown)++;
      }
   }
}

/* -------------------------------------------------------- per-frame scratch
 *
 * the matcher is a REGION GROW, not a grid placement. Per frame it needs
 *   * every profile variant resolved to this frame's atlas, and the reverse map
 *     so a frame tile can name its variant in O(1);
 *   * an exact-position index per layer class, so a tile's four 8-px
 *     neighbours are one hash probe each;
 *   * a growable region, a shrinking candidate list, and a small occupancy
 *     bitmap for `Shape.IsSolid`.
 * Everything here is allocated once and reused for the life of the frame
 * object; nothing in the per-frame path calls malloc in the steady state. */

typedef struct
{
   /* atlas */
   uint16_t *canon;          /* atlas idx -> canonical idx of identical bytes */
   uint8_t  *atlas_empty;    /* atlas idx -> all-zero                         */
   uint32_t  atlas_cap;
   uint32_t *ahash; uint32_t ahash_mask;

   /* profile variant <-> this frame's tile key */
   int32_t  *var_key;  uint32_t var_key_cap;   /* variant -> key, -1 if absent */
   int32_t  *key_var;  uint32_t key_var_cap;   /* key -> variant, -1 if absent */

   /* per layer class: exact-position buckets */
   int32_t  *phead[2]; uint32_t phead_cap;
   int32_t  *pnext;    uint32_t pnext_cap;
   uint32_t  pmask;

   /* per-tile derived */
   int32_t  *tile_var; uint32_t tile_cap;      /* profile variant, -1 if none  */
   int32_t  *nbr;      uint32_t nbr_cap;       /* 4 neighbours per tile, or -1 */
   uint8_t  *tile_lc;
   uint8_t  *claimed;
   uint8_t  *inregion;
   uint8_t  *drop;           /* culled / overwritten, never drawn        */
   int16_t  *tgx, *tgy;      /* the tile's grid cell * 8 (3dSen tPos)     */
   int32_t   bgrid[34 * 33]; /* Frame.bgTiles, GridWidth x GridHeight    */

   /* scan orders */
   uint64_t *sortk;  uint32_t sortk_cap;
   uint32_t *ord[2]; uint32_t ord_n[2], ord_cap;

   /* the region under construction */
   uint32_t *region; uint32_t region_cap;
   uint32_t *cand, *cand2; uint32_t cand_cap;

   /* Shape.IsSolid scratch: per-row and per-column occupied extents */
   int32_t  *rowmin, *rowmax, *colmin, *colmax; uint32_t rc_cap;
   uint8_t  *occ; uint32_t occ_cap;

   /* per atlas entry, the opaque pixels' box (x0, y0, x1, y1), and a
    * stamp per profile variant for counting a region's distinct identities */
   int8_t   *abox;  uint32_t abox_cap;
   uint32_t *vstamp; uint32_t vstamp_cap, stamp;
} Ra3dScratch;

static uint32_t ra3d_pos_hash(int32_t x, int32_t y)
{
   uint32_t h = (uint32_t)(x * 73856093) ^ (uint32_t)(y * 19349663);
   h ^= h >> 15; h *= 2246822519u; h ^= h >> 13;
   return h;
}

#define RA3D_ENS(ptr, cap, need, esz) \
   do { if ((need) > (cap)) { uint32_t c_ = (cap) ? (cap) : 64; \
        while (c_ < (need)) c_ *= 2; \
        { void *np = realloc((ptr), (size_t)c_ * (esz)); if (!np) return 0; \
          (ptr) = np; (cap) = c_; } } } while (0)

static int ra3d_scratch_ensure(Ra3dScratch *s, uint32_t atlas, uint32_t tiles,
                               uint32_t vars)
{
   uint32_t keys = (atlas ? atlas : 1) * 4;

   { void *p = s->canon; RA3D_ENS(p, s->atlas_cap, atlas ? atlas : 1, sizeof(uint16_t));
     s->canon = (uint16_t*)p; }
   s->atlas_empty = (uint8_t*)realloc(s->atlas_empty, s->atlas_cap);
   if (!s->atlas_empty) return 0;

   if (!s->ahash)
   {
      s->ahash_mask = (1u << 12) - 1u;
      s->ahash = (uint32_t*)malloc((size_t)(s->ahash_mask + 1) * sizeof(uint32_t));
      if (!s->ahash) return 0;
   }

   { void *p = s->var_key; RA3D_ENS(p, s->var_key_cap, vars ? vars : 1, sizeof(int32_t));
     s->var_key = (int32_t*)p; }
   { void *p = s->key_var; RA3D_ENS(p, s->key_var_cap, keys, sizeof(int32_t));
     s->key_var = (int32_t*)p; }

   { void *p = s->pnext; RA3D_ENS(p, s->pnext_cap, tiles ? tiles : 1, sizeof(int32_t));
     s->pnext = (int32_t*)p; }
   { void *p = s->tile_var; RA3D_ENS(p, s->tile_cap, tiles ? tiles : 1, sizeof(int32_t));
     s->tile_var = (int32_t*)p; }
   { void *p = s->nbr; RA3D_ENS(p, s->nbr_cap, (tiles ? tiles : 1) * 4, sizeof(int32_t));
     s->nbr = (int32_t*)p; }
   s->tile_lc   = (uint8_t*)realloc(s->tile_lc,   s->tile_cap);
   s->claimed   = (uint8_t*)realloc(s->claimed,   s->tile_cap);
   s->inregion  = (uint8_t*)realloc(s->inregion,  s->tile_cap);
   s->drop      = (uint8_t*)realloc(s->drop,      s->tile_cap);
   s->tgx       = (int16_t*)realloc(s->tgx,       (size_t)s->tile_cap * sizeof(int16_t));
   s->tgy       = (int16_t*)realloc(s->tgy,       (size_t)s->tile_cap * sizeof(int16_t));
   if (!s->tile_lc || !s->claimed || !s->inregion || !s->drop || !s->tgx || !s->tgy)
      return 0;

   { void *p = s->sortk; RA3D_ENS(p, s->sortk_cap, tiles ? tiles : 1, sizeof(uint64_t));
     s->sortk = (uint64_t*)p; }
   { void *p0 = s->ord[0], *p1 = s->ord[1];
     uint32_t c0 = s->ord_cap, c1 = s->ord_cap;
     RA3D_ENS(p0, c0, tiles ? tiles : 1, sizeof(uint32_t));
     RA3D_ENS(p1, c1, tiles ? tiles : 1, sizeof(uint32_t));
     s->ord[0] = (uint32_t*)p0; s->ord[1] = (uint32_t*)p1;
     s->ord_cap = c0 > c1 ? c0 : c1; }
   { void *p = s->region; RA3D_ENS(p, s->region_cap, tiles ? tiles : 1, sizeof(uint32_t));
     s->region = (uint32_t*)p; }

   if (!s->phead[0])
   {
      s->pmask = (1u << 13) - 1u;
      s->phead[0] = (int32_t*)malloc((size_t)(s->pmask + 1) * sizeof(int32_t));
      s->phead[1] = (int32_t*)malloc((size_t)(s->pmask + 1) * sizeof(int32_t));
      if (!s->phead[0] || !s->phead[1]) return 0;
      s->phead_cap = s->pmask + 1;
   }
   {  /* the screen is 34x32 tiles at most, plus the fine-scroll overhang */
      uint32_t need = 64;
      void *a = s->rowmin, *b = s->rowmax, *c = s->colmin, *d = s->colmax;
      uint32_t ca = s->rc_cap, cb = s->rc_cap, cc = s->rc_cap, cd = s->rc_cap;
      RA3D_ENS(a, ca, need, sizeof(int32_t));
      RA3D_ENS(b, cb, need, sizeof(int32_t));
      RA3D_ENS(c, cc, need, sizeof(int32_t));
      RA3D_ENS(d, cd, need, sizeof(int32_t));
      s->rowmin = (int32_t*)a; s->rowmax = (int32_t*)b;
      s->colmin = (int32_t*)c; s->colmax = (int32_t*)d;
      s->rc_cap = ca;
   }
   { void *p = s->occ; RA3D_ENS(p, s->occ_cap, 64u * 64u, sizeof(uint8_t));
     s->occ = (uint8_t*)p; }
   { void *p = s->abox; RA3D_ENS(p, s->abox_cap, (atlas ? atlas : 1) * 4, sizeof(int8_t));
     s->abox = (int8_t*)p; }
   if ((vars ? vars : 1) > s->vstamp_cap)
   {
      uint32_t c = s->vstamp_cap ? s->vstamp_cap : 64;
      void *np;
      while (c < (vars ? vars : 1)) c *= 2;
      np = realloc(s->vstamp, (size_t)c * sizeof(uint32_t));
      if (!np) return 0;
      memset((uint32_t*)np + s->vstamp_cap, 0, (size_t)(c - s->vstamp_cap) * sizeof(uint32_t));
      s->vstamp = (uint32_t*)np; s->vstamp_cap = c;
   }
   return 1;
}

static int ra3d_cand_ensure(Ra3dScratch *s, uint32_t need)
{
   void *a = s->cand, *b = s->cand2;
   uint32_t ca = s->cand_cap, cb = s->cand_cap;
   RA3D_ENS(a, ca, need ? need : 1, sizeof(uint32_t));
   RA3D_ENS(b, cb, need ? need : 1, sizeof(uint32_t));
   s->cand = (uint32_t*)a; s->cand2 = (uint32_t*)b;
   s->cand_cap = ca < cb ? ca : cb;
   return 1;
}
#undef RA3D_ENS

static int ra3d_u64_cmp(const void *a, const void *b)
{
   uint64_t x = *(const uint64_t*)a, y = *(const uint64_t*)b;
   return x < y ? -1 : (x > y ? 1 : 0);
}

static double ra3d_now_ms(void)
{
   struct timespec ts;
#if defined(CLOCK_MONOTONIC)
   clock_gettime(CLOCK_MONOTONIC, &ts);
#else
   clock_gettime(CLOCK_REALTIME, &ts);
#endif
   return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

/* absDirs, verbatim: right, down, up, left. */
static const int8_t RA3D_DX[4] = { 8, 0, 0, -8 };
static const int8_t RA3D_DY[4] = { 0, 8, -8, 0 };

/* sprite adjacency within `tol` px — the direction (order:
 * 0 right, 1 down, 2 up, 3 left) in which b sits next to a, or -1. */
static int ra3d_connected(const Ra3dSceneTile *a, const Ra3dSceneTile *b, int tol)
{
   int dy = a->Y - b->Y, dx = a->X - b->X, e;
   if ((dy < 0 ? -dy : dy) <= tol)
   {
      e = a->X + 8 - b->X; if ((e < 0 ? -e : e) <= tol) return 0;
      e = b->X + 8 - a->X; if ((e < 0 ? -e : e) <= tol) return 3;
   }
   if ((dx < 0 ? -dx : dx) <= tol)
   {
      e = a->Y + 8 - b->Y; if ((e < 0 ? -e : e) <= tol) return 1;
      e = b->Y + 8 - a->Y; if ((e < 0 ? -e : e) <= tol) return 2;
   }
   return -1;
}

static int32_t ra3d_floor8(int32_t v) { return v >= 0 ? v / 8 : -((-v + 7) / 8); }

/* Shape.IsBig() */
#define RA3D_BIG_W 28
#define RA3D_BIG_H 26
#define RA3D_MIN_SOLID_TILES  8
#define RA3D_MIN_SOLID_IDENTS 2

/* The tile at exactly (x, y) in layer class `lc`, lowest scene index first —
 * the Python's `by_pos` is built with setdefault, so the first tile wins. */
static int32_t ra3d_at(const Ra3dScratch *s, const Ra3dScene *scene,
                       uint8_t lc, int32_t x, int32_t y)
{
   uint32_t h = ra3d_pos_hash(x, y) & s->pmask;
   int32_t it, best = -1;
   for (it = s->phead[lc][h]; it >= 0; it = s->pnext[it])
   {
      const Ra3dSceneTile *t = &scene->Tiles[it];
      if (t->X == x && t->Y == y && (best < 0 || it < best)) best = it;
   }
   return best;
}

/* the pattern's mesher — rm 2 forces MARCHING, rm 1/3 force the
 * greedy meshers (GREEDY_MULTICOLOR draws the same pixels as mono GREEDY, so
 * both are our greedy), rm 0 follows the user setting (`retina`). */
static uint32_t ra3d_mode_flags(const Ra3dShape3D *sh, const Ra3dKnobs *k)
{
   uint32_t f = 0u;
   if (!sh) return 0u;
   if (sh->render_mode == 2 || (sh->render_mode == 0 && k && k->retina))
      f |= RA3D_INST_MARCHING;
   if (!k || k->tile_share)
      f |= RA3D_INST_TILESHARE;
   return f;
}

/* 3dSen's cast / receive rules per pattern, material and renderStyle.
 * `layer` 0 (UNIDENTIFIED) counts as L1 (3dSen's default layer; a
 * profile's own default layer is not read). */
static uint32_t ra3d_shadow_flags(const Ra3dProfile *prof, const Ra3dShape3D *sh,
                                  uint8_t layer, float alpha)
{
   uint32_t f = 0;
   int style = sh ? sh->render_style : 1;
   uint8_t rl = (layer == 0 || layer > 5) ? 2 : layer;
   int lc = prof ? prof->layer_cast[rl] : (rl == 2);
   int lr = prof ? prof->layer_recv[rl] : (rl >= 2);
   if (rl == 1)                     { lc = 0; lr = 0; }     /* ui */
   if (sh && sh->tag_nocast)        lc = 0;
   if (sh && sh->tag_norecv)        lr = 0;
   if (style != 2 && alpha < 1.0f)  lc = 0;                 /* translucent: no caster */
   if (style == 0)                  { f |= RA3D_INST_HIDDEN; lc = 0; }
   /* shadows-only is set whatever the cast flag says, as in 3dSen */
   if (style == 2)                  { f |= RA3D_INST_SHADOWONLY; lc = 1; }
   if (!lc) f |= RA3D_INST_NOCAST;
   if (!lr) f |= RA3D_INST_NORECV;
   return f;
}

/* Placement of one instance from 3dSen-frame Pattern3D values (
 * shared by build_frame and the Lua write-back). `in->pos/size` must be
 * set. Returns 1 when flattened it.
 *
 * with `unity` on and a region, the pivot is converted against
 * 3dSen's own box — the region's TIGHT pixel box (GetPos uses
 * the opaque pixels' extents) — rather than our tile-grid
 * box, so a hinge a script computes from BottomLeft/GetPos (Punch-Out's
 * panel items) lands on the same pixel. Without a region (or unity off) it is
 * p -> 1 - p on the instance box. */
static int ra3d_inst_xform(Ra3dGeoInstance *in, const Ra3dGeoRegion *rg,
                           const float scale[3], const float rot[3],
                           const float offset[3], const float pivot[3],
                           int unity, int flat)
{
   int fl = 0;
   memcpy(in->scale,  scale,  sizeof(float) * 3);
   memcpy(in->rot,    rot,    sizeof(float) * 3);
   if (flat)
   {  /* stand a laid-flat diorama shape upright. */
      float ax = in->rot[0] < 0.0f ? -in->rot[0] : in->rot[0];
      while (ax >= 180.0f) ax -= 180.0f;
      if (ax >= 45.0f && ax <= 135.0f)
      { in->rot[0] = in->rot[1] = in->rot[2] = 0.0f; fl = 1; }
   }
   memcpy(in->offset, offset, sizeof(float) * 3);
   memcpy(in->pivot,  pivot,  sizeof(float) * 3);
   if (unity)
   {  /* 3dSen frame -> NES world */
      in->offset[1] = -in->offset[1]; in->offset[2] = -in->offset[2];
      in->rot[1]    = -in->rot[1];    in->rot[2]    = -in->rot[2];
      in->pivot[2]  = 1.0f - in->pivot[2];
      if (rg && in->size[0] > 0.0f && in->size[1] > 0.0f)
      {
         float hx = (float)rg->px0 + pivot[0] * (float)(rg->px1 + 1 - rg->px0);
         float hy = (float)(rg->py1 + 1) - pivot[1] * (float)(rg->py1 + 1 - rg->py0);
         in->pivot[0] = (hx - in->pos[0]) / in->size[0];
         in->pivot[1] = (hy - in->pos[1]) / in->size[1];
      }
      else
         in->pivot[1] = 1.0f - in->pivot[1];
   }
   return fl;
}

static uint32_t ra3d_sprite_order_flags(const Ra3dScene *scene, const uint32_t *tiles,
                                        uint32_t n)
{
   uint32_t a, f = 0u, order = 0x3Fu;
   for (a = 0; a < n; a++)
   {
      const Ra3dSceneTile *t = &scene->Tiles[tiles[a]];
      if (t->Layer == 0) continue;
      if (t->Layer == 1) f |= RA3D_INST_BEHIND;
      if ((uint32_t)(t->Oam & 0x3F) < order) order = (uint32_t)(t->Oam & 0x3F);
   }
   return f | (order << RA3D_INST_ORDER_SHIFT);
}

int ra3d_build_frame(const Ra3dProfile *prof, const Ra3dScene *scene,
                     const Ra3dKnobs *k, Ra3dGeoFrame *out)
{
   Ra3dScratch *s;
   uint32_t i, t, atlas = scene->AtlasCount, tiles = scene->TileCount;
   uint32_t nkeys = (atlas ? atlas : 1) * 4;
   double t0 = ra3d_now_ms();
   int pass, flat, et, gm;
   float cl[4];

   if (!prof || !scene || !out) return 0;
   gm = k->grid_match != 0;
   if (k->cull_set)        memcpy(cl, k->cull, sizeof(cl));
   else if (prof->clip_set) memcpy(cl, prof->clip, sizeof(cl));
   else { cl[0] = 0.1f; cl[1] = 8.1f; cl[2] = 8.1f; cl[3] = 0.1f; }
   et = k->empty_tile >= 0 ? (k->empty_tile != 0) : ra3d_profile_empty_tile(prof);
   {  /* resolve flat_shapes' auto default once per frame */
      int lcp = k->lua_active ? (k->lua_localcam != 0)
                              : (ra3d_profile_localcam(prof, NULL, NULL) & 1);
      int lca = k->localcam_active < 0 ? lcp : k->localcam_active;
      flat = k->flat_shapes >= 0 ? k->flat_shapes : (lcp && !lca);
   }
   if (!out->scratch)
   {
      out->scratch = calloc(1, sizeof(Ra3dScratch));
      if (!out->scratch) return 0;
   }
   s = (Ra3dScratch*)out->scratch;
   if (!ra3d_scratch_ensure(s, atlas, tiles, prof->vars.n)) return 0;
   if (!ra3d_cand_ensure(s, prof->max_cands)) return 0;

   out->instance_count = out->cell_count = 0;
   out->frame = scene->FrameNumber;
   out->xpx_n = 0;
   if (++out->tt_stamp == 0)
   {
      if (out->tt_gen) memset(out->tt_gen, 0, (size_t)out->tt_cap * sizeof(uint32_t));
      out->tt_stamp = 1;
   }
   if (out->dtex_serial != prof->serial && out->tt_gen)
      memset(out->tt_gen, 0, (size_t)out->tt_cap * sizeof(uint32_t));
   if (out->dtex_serial != prof->serial)
   {  /* the profile's Direct textures, once per profile */
      if (prof->dtex.n > out->dtex_cap)
      {
         uint32_t *nd = (uint32_t *)realloc(out->dtex, (size_t)prof->dtex.n * sizeof(uint32_t));
         if (!nd) return 0;
         out->dtex = nd; out->dtex_cap = prof->dtex.n;
      }
      if (prof->dtex.n) memcpy(out->dtex, prof->dtex.v, (size_t)prof->dtex.n * sizeof(uint32_t));
      out->dtex_n = prof->dtex.n;
      out->dtex_serial = prof->serial;
      out->dtex_gen++;
   }
   out->scene_tiles = tiles;
   out->non_empty = out->candidates = 0;
   out->pattern_instances = out->multi_tile = out->clipped = 0;
   out->fallbacks = out->covered = 0;
   out->flattened = 0;
   out->variants = out->lua_hidden = 0;
   out->region_count = 0;
   out->rtile_n = 0;

   /* ---- canonicalise the atlas: two entries with identical CHR bytes are one
    * identity (the atlas is keyed by bank-resolved ADDRESS, so duplicates are
    * normal). The Python compares tiles by their hex, which unifies them; this
    * is how the C keeps parity while still using integer keys. */
   memset(s->ahash, 0xFF, (size_t)(s->ahash_mask + 1) * sizeof(uint32_t));
   for (i = 0; i < atlas; i++)
   {
      const uint8_t *b = scene->Atlas + (size_t)i * 16;
      uint32_t h = 2166136261u, j, slot;
      for (j = 0; j < 16; j++) { h ^= b[j]; h *= 16777619u; }
      slot = h & s->ahash_mask;
      s->canon[i] = (uint16_t)i;
      for (;;)
      {
         uint32_t e = s->ahash[slot];
         if (e == 0xFFFFFFFFu) { s->ahash[slot] = i; break; }
         if (memcmp(scene->Atlas + (size_t)e * 16, b, 16) == 0)
         { s->canon[i] = (uint16_t)e; break; }
         slot = (slot + 1) & s->ahash_mask;
      }
      s->atlas_empty[i] = (memcmp(b, RA3D_ZERO16, 16) == 0);
      {  /* Tile2D.LoadRaw's start/end — blank stays (7,7)-(0,0) */
         int x0 = 7, y0 = 7, x1 = 0, y1 = 0, yy;
         for (yy = 0; yy < 8; yy++)
         {
            uint8_t m = (uint8_t)(b[yy] | b[8 + yy]);
            int xx;
            if (!m) continue;
            if (yy < y0) y0 = yy;
            if (yy > y1) y1 = yy;
            for (xx = 0; xx < 8; xx++)
               if (m & (0x80u >> xx)) { if (xx < x0) x0 = xx; if (xx > x1) x1 = xx; }
         }
         s->abox[i * 4 + 0] = (int8_t)x0; s->abox[i * 4 + 1] = (int8_t)y0;
         s->abox[i * 4 + 2] = (int8_t)x1; s->abox[i * 4 + 3] = (int8_t)y1;
      }
   }

   /* ---- resolve every profile variant to this frame's key, and back ---- */
   for (i = 0; i < nkeys; i++) s->key_var[i] = -1;
   for (i = 0; i < prof->vars.n; i++)
   {
      const Ra3dVariant *v = &prof->vars.v[i];
      uint32_t h = 2166136261u, j, slot;
      int32_t key = -1;
      for (j = 0; j < 16; j++) { h ^= v->chr[j]; h *= 16777619u; }
      slot = h & s->ahash_mask;
      for (;;)
      {
         uint32_t e = s->ahash[slot];
         if (e == 0xFFFFFFFFu) break;
         if (memcmp(scene->Atlas + (size_t)e * 16, v->chr, 16) == 0)
         { key = (int32_t)(s->canon[e] * 4 + v->fx + 2 * v->fy); break; }
         slot = (slot + 1) & s->ahash_mask;
      }
      s->var_key[i] = key;
      /* interning makes (chr, fx, fy) unique, so the map back is a function */
      if (key >= 0 && (uint32_t)key < nkeys) s->key_var[key] = (int32_t)i;
   }

   /* ---- index the scene ---- */
   for (i = 0; i <= s->pmask; i++) { s->phead[0][i] = -1; s->phead[1][i] = -1; }
   memset(s->claimed,  0, tiles);
   memset(s->inregion, 0, tiles);
   memset(s->drop,     0, tiles);
   if (gm) memset(s->bgrid, 0xFF, sizeof(s->bgrid));
   s->ord_n[0] = s->ord_n[1] = 0;
   for (t = 0; t < tiles; t++)
   {
      const Ra3dSceneTile *tl = &scene->Tiles[t];
      uint8_t lc = tl->Layer == 0 ? 0 : 1;
      uint32_t hp = ra3d_pos_hash(tl->X, tl->Y) & s->pmask;
      int blank = 1;
      s->tile_lc[t] = lc;
      s->pnext[t] = s->phead[lc][hp]; s->phead[lc][hp] = (int32_t)t;
      s->tile_var[t] = -1;
      s->tgx[t] = tl->X; s->tgy[t] = tl->Y;
      if (tl->Chr < atlas)
      {
         uint32_t key = (uint32_t)s->canon[tl->Chr] * 4u
                      + (tl->Flags & 1u) + ((tl->Flags >> 1) & 1u) * 2u;
         if (key < nkeys) s->tile_var[t] = s->key_var[key];
         if (!s->atlas_empty[tl->Chr]) { out->non_empty++; blank = 0; }
         /* a blank background tile is matcher input
          * only under Setting.EmptyTile; a blank sprite never is */
         else if (lc != 0 || !et) s->tile_var[t] = -1;
      }
      if (gm)
      {  /* 3dSen's tile filter
          * and grids. A dropped tile is neither matched nor drawn. */
         if (!((float)(tl->X + 8) > cl[0] && (float)tl->X <= 256.0f - cl[2] &&
               (float)(tl->Y + 8) > cl[3] && (float)tl->Y <= 248.0f - cl[1]) ||
             (lc != 0 && tl->Y >= 240))
         { s->drop[t] = 1; s->tile_var[t] = -1; }
         else if (lc == 0)
         {
            int32_t gx = ra3d_floor8(tl->X + 7) + 1, gy = ra3d_floor8(tl->Y + 7) + 1;
            if (gx < 0 || gx >= 34 || gy < 0 || gy >= 33)
            { s->drop[t] = 1; s->tile_var[t] = -1; }
            else if (tl->Chr < atlas && (!blank || et))
            {  /* Frame.bgTiles[cell]: a later tile overwrites the earlier */
               int32_t *c = &s->bgrid[gy * 34 + gx];
               if (*c >= 0) { s->drop[*c] = 1; s->tile_var[*c] = -1; }
               *c = (int32_t)t;
            }
            s->tgx[t] = (int16_t)(gx * 8); s->tgy[t] = (int16_t)(gy * 8);
         }
         else
         {  /* World2Grid(bg: false) = (x >> 3, y >> 3) */
            s->tgx[t] = (int16_t)(ra3d_floor8(tl->X) * 8);
            s->tgy[t] = (int16_t)(ra3d_floor8(tl->Y) * 8);
         }
      }
      /* background is scanned in (y, x) order, 3dSen's default;
       * sprites keep OAM order, which is the order the stream publishes them */
      if (lc == 0)
         s->sortk[s->ord_n[0]++] = ((uint64_t)(uint32_t)(tl->Y + 32768) << 40)
                                 | ((uint64_t)(uint32_t)(tl->X + 32768) << 24)
                                 | (uint64_t)t;
      else
         s->ord[1][s->ord_n[1]++] = t;
   }
   qsort(s->sortk, s->ord_n[0], sizeof(uint64_t), ra3d_u64_cmp);
   for (i = 0; i < s->ord_n[0]; i++)
      s->ord[0][i] = (uint32_t)(s->sortk[i] & 0xFFFFFFu);

   /* Each tile's four 8-px neighbours, resolved once. The grow visits the same
    * neighbours on every pass and on every rolled-back attempt, so caching them
    * is what keeps the worst frame measured (Ice Hockey f1500) inside a
    * fraction of a millisecond. */
   for (t = 0; t < tiles; t++)
   {
      const Ra3dSceneTile *tl = &scene->Tiles[t];
      uint8_t lc = s->tile_lc[t];
      int d;
      if (gm && lc == 0)
      {  /* neighbours by grid cell (absDirs = +1, +W, -W, -1) */
         int32_t gx = s->tgx[t] / 8, gy = s->tgy[t] / 8;
         for (d = 0; d < 4; d++)
         {
            int32_t nx = gx + RA3D_DX[d] / 8, ny = gy + RA3D_DY[d] / 8;
            s->nbr[t * 4 + d] = (s->drop[t] || nx < 0 || nx >= 34 || ny < 0 || ny >= 33)
                              ? -1 : s->bgrid[ny * 34 + nx];
         }
         continue;
      }
      for (d = 0; d < 4; d++)
         s->nbr[t * 4 + d] = ra3d_at(s, scene, lc, tl->X + RA3D_DX[d],
                                                   tl->Y + RA3D_DY[d]);
   }

   /* ---- three region-grow passes: background gated, background ungated,
    * sprites ungated, as 3dSen segments them ---- */
   for (pass = 0; pass < 3; pass++)
   {
      uint8_t lc   = pass == 2 ? 1 : 0;
      int     gate = (pass == 0);
      uint32_t oi;
      if (pass == 1)                      /* rolled-back tiles released */
         for (t = 0; t < tiles; t++) if (s->claimed[t] == 2) s->claimed[t] = 0;
      for (oi = 0; oi < s->ord_n[lc]; oi++)
      {
         uint32_t seed = s->ord[lc][oi];
         int32_t  sv   = s->tile_var[seed];
         uint32_t nc, qi, rn = 0;
         int32_t  minx, maxx, miny, maxy;
         int32_t  gminx, gmaxx, gminy, gmaxy;   /* tile-grid box (x8) */
         uint32_t rw, rh, gw, gh;
         int      spal = lc ? prof->same_sp_pal : prof->same_bg_pal;
         int      sscan = gm && lc;              /* sprites: adjacency scan    */

         if (s->claimed[seed] || sv < 0) continue;
         nc = prof->keypat_off[sv + 1] - prof->keypat_off[sv];
         if (!nc) continue;
         if (!ra3d_cand_ensure(s, nc)) return 0;
         memcpy(s->cand, prof->keypat.v + prof->keypat_off[sv],
                (size_t)nc * sizeof(uint32_t));

         s->region[rn++] = seed;
         s->inregion[seed] = 1;
         minx = maxx = scene->Tiles[seed].X;
         miny = maxy = scene->Tiles[seed].Y;
         gminx = gmaxx = s->tgx[seed];
         gminy = gmaxy = s->tgy[seed];

         for (qi = 0; qi < rn; qi++)
         {
            const Ra3dSceneTile *tu = &scene->Tiles[s->region[qi]];
            uint32_t ku = (uint32_t)s->tile_var[s->region[qi]];
            uint32_t d, dn = sscan ? s->ord_n[1] : 4;
            for (d = 0; d < dn; d++)
            {
               int32_t v;
               int dir;
               const Ra3dSceneTile *tv;
               uint32_t kv, n2 = 0, c;
               int32_t nminx, nmaxx, nminy, nmaxy;
               uint32_t nw, nh;
               if (sscan)
               {
                  v = (int32_t)s->ord[1][d];
                  if (s->inregion[v] || s->claimed[v] || s->tile_var[v] < 0) continue;
                  dir = ra3d_connected(tu, &scene->Tiles[v], prof->sp_tol);
                  if (dir < 0) continue;
               }
               else
               {
                  v = s->nbr[s->region[qi] * 4 + d];
                  dir = (int)d;
                  if (v < 0 || s->inregion[v] || s->claimed[v]) continue;
                  if (s->tile_var[v] < 0) continue;
               }
               tv = &scene->Tiles[v];
               if (gm && spal && tv->Palette != tu->Palette) continue;
               kv = (uint32_t)s->tile_var[v];
               nminx = gminx < s->tgx[v] ? gminx : s->tgx[v];
               nmaxx = gmaxx > s->tgx[v] ? gmaxx : s->tgx[v];
               nminy = gminy < s->tgy[v] ? gminy : s->tgy[v];
               nmaxy = gmaxy > s->tgy[v] ? gmaxy : s->tgy[v];
               nw = (uint32_t)((nmaxx - nminx) / 8) + 1;
               nh = (uint32_t)((nmaxy - nminy) / 8) + 1;
               for (c = 0; c < nc; c++)
               {
                  const Ra3dPattern *pa = &prof->patterns.v[s->cand[c]];
                  if (nw > pa->cw || nh > pa->ch) continue;
                  if (pa->skip_geo ? ra3d_has_ident(prof, pa, kv)
                                   : ra3d_is_link(prof, s->cand[c], ku, kv, dir))
                     s->cand2[n2++] = s->cand[c];
               }
               if (!n2) continue;
               { uint32_t *sw = s->cand; s->cand = s->cand2; s->cand2 = sw; }
               nc = n2;
               s->region[rn++] = (uint32_t)v;
               s->inregion[v] = 1;
               gminx = nminx; gmaxx = nmaxx; gminy = nminy; gmaxy = nmaxy;
               if (tv->X < minx) minx = tv->X;
               if (tv->X > maxx) maxx = tv->X;
               if (tv->Y < miny) miny = tv->Y;
               if (tv->Y > maxy) maxy = tv->Y;
            }
         }

         /* the cell grid the renderer draws: pixel-anchored, each tile in
          * the cell nearest its own position (+ 4 so a row at another
          * fine-X, or a sprite joined by tolerance, still fits) */
         rw = (uint32_t)((maxx - minx + 4) / 8) + 1;
         rh = (uint32_t)((maxy - miny + 4) / 8) + 1;
         /* 3dSen's tSize, which the gate measures */
         gw = (uint32_t)((gmaxx - gminx) / 8) + 1;
         gh = (uint32_t)((gmaxy - gminy) / 8) + 1;

         if (gate)
         {
            int keep = (gw >= RA3D_BIG_W || gh >= RA3D_BIG_H);   /* IsBig() */
            if (!keep && rn >= RA3D_MIN_SOLID_TILES)
            {
               /* distinct identities >= 2 */
               uint32_t a, b; int distinct = 0;
               for (a = 1; a < rn && !distinct; a++)
                  if (s->tile_var[s->region[a]] != s->tile_var[s->region[0]])
                     distinct = 1;
               if (distinct && gw < s->rc_cap && gh < s->rc_cap &&
                   gw * gh <= s->occ_cap)
               {
                  /* Shape.IsSolid(): no position strictly inside the bounding
                   * box is an enclosed hole. */
                  int solid = 1;
                  memset(s->occ, 0, (size_t)gw * gh);
                  for (a = 0; a < gw; a++) { s->colmin[a] = 1 << 30; s->colmax[a] = -1; }
                  for (a = 0; a < gh; a++) { s->rowmin[a] = 1 << 30; s->rowmax[a] = -1; }
                  for (a = 0; a < rn; a++)
                  {
                     int32_t gx = (s->tgx[s->region[a]] - gminx) / 8;
                     int32_t gy = (s->tgy[s->region[a]] - gminy) / 8;
                     s->occ[(uint32_t)gy * gw + (uint32_t)gx] = 1;
                     if (gx < s->rowmin[gy]) s->rowmin[gy] = gx;
                     if (gx > s->rowmax[gy]) s->rowmax[gy] = gx;
                     if (gy < s->colmin[gx]) s->colmin[gx] = gy;
                     if (gy > s->colmax[gx]) s->colmax[gx] = gy;
                  }
                  for (b = 1; b + 1 < gh && solid; b++)
                     for (a = 1; a + 1 < gw; a++)
                     {
                        if (s->occ[b * gw + a]) continue;
                        if (s->rowmin[b] < (int32_t)a && s->rowmax[b] > (int32_t)a &&
                            s->colmin[a] < (int32_t)b && s->colmax[a] > (int32_t)b)
                        { solid = 0; break; }
                     }
                  keep = solid;
               }
            }
            if (!keep)
            {  /* rolled back. 3dSen releases rolled-back tiles only after the
                * whole pass, so until then the
                * tiles stay taken (claimed = 2, freed below). */
               uint32_t a;
               for (a = 0; a < rn; a++)
               {
                  s->inregion[s->region[a]] = 0;
                  if (gm) s->claimed[s->region[a]] = 2;
               }
               continue;
            }
         }

         /* ---- accept ---- */
         {
            uint32_t a, best = s->cand[0];
            for (a = 1; a < nc; a++)
            {
               const Ra3dPattern *x = &prof->patterns.v[s->cand[a]];
               const Ra3dPattern *y = &prof->patterns.v[best];
               if (x->ident_count < y->ident_count ||
                   (x->ident_count == y->ident_count && s->cand[a] < best))
                  best = s->cand[a];
            }
            for (a = 0; a < rn; a++)
            { s->claimed[s->region[a]] = 1; s->inregion[s->region[a]] = 0; }
            out->candidates++;

            {
               const Ra3dPattern *pa = &prof->patterns.v[best];
               uint32_t ncell = rw * rh, base, vi, v0, v1;
               /* one instance per Pattern3D of the pattern (3dSen draws
                * each with renderStyle > 0), all sharing the region's cells */
               if (!pa->shape_count)           { v0 = 0; v1 = 1; }
               else if (k->pattern3d_index < 0) { v0 = 0; v1 = pa->shape_count; }
               else
               {
                  v0 = (uint32_t)k->pattern3d_index < pa->shape_count
                     ? (uint32_t)k->pattern3d_index : 0;
                  v1 = v0 + 1;
               }
               if (!ra3d_grow((void**)&out->cells, &out->cell_cap,
                              out->cell_count + ncell, sizeof(Ra3dGeoCell)))
                  return 0;
               base = out->cell_count;
               for (a = 0; a < ncell; a++)
               {
                  Ra3dGeoCell z;
                  z.gx = (uint8_t)(a % rw); z.gy = (uint8_t)(a / rw);
                  z.pal = 0; z.flip = 0; z.chr = RA3D_CELL_EMPTY; z.pad = 0;
                  out->cells[base + a] = z;
               }
               for (a = 0; a < rn; a++)
               {
                  const Ra3dSceneTile *tr = &scene->Tiles[s->region[a]];
                  int32_t gx = (tr->X - minx + 4) / 8, gy = (tr->Y - miny + 4) / 8;
                  Ra3dGeoCell *z;
                  if (gx < 0 || gy < 0 || (uint32_t)gx >= rw || (uint32_t)gy >= rh)
                     continue;
                  z = &out->cells[base + (uint32_t)gy * rw + (uint32_t)gx];
                  z->pal  = tr->Palette;
                  z->flip = (uint8_t)(tr->Flags & 3u);
                  z->chr  = tr->Chr;
               }
               out->cell_count = base + ncell;

               /* the region as 3dSen's Shape sees it (Lua's shape2D) */
               if (!ra3d_grow((void**)&out->regions, &out->region_cap,
                              out->region_count + 1, sizeof(Ra3dGeoRegion)))
                  return 0;
               {
                  Ra3dGeoRegion *rg = &out->regions[out->region_count];
                  int32_t p0x = 1 << 20, p0y = 1 << 20, p1x = -(1 << 20), p1y = -(1 << 20);
                  uint32_t nid = 0;
                  if (++s->stamp == 0) { memset(s->vstamp, 0, (size_t)s->vstamp_cap * 4); s->stamp = 1; }
                  rg->flags = lc ? 0 : 1;
                  for (a = 0; a < rn; a++)
                  {
                     const Ra3dSceneTile *tr = &scene->Tiles[s->region[a]];
                     int32_t tv2 = s->tile_var[s->region[a]];
                     int bx0 = 7, by0 = 7, bx1 = 0, by1 = 0;
                     if (tr->Chr < atlas)
                     {
                        const int8_t *bb = &s->abox[tr->Chr * 4];
                        bx0 = bb[0]; by0 = bb[1]; bx1 = bb[2]; by1 = bb[3];
                        if (tr->Flags & 1u) { int q = bx0; bx0 = 7 - bx1; bx1 = 7 - q; }
                        if (tr->Flags & 2u) { int q = by0; by0 = 7 - by1; by1 = 7 - q; }
                     }
                     if (tr->X + bx0 < p0x) p0x = tr->X + bx0;
                     if (tr->Y + by0 < p0y) p0y = tr->Y + by0;
                     if (tr->X + bx1 > p1x) p1x = tr->X + bx1;
                     if (tr->Y + by1 > p1y) p1y = tr->Y + by1;
                     if (tv2 >= 0 && (uint32_t)tv2 < s->vstamp_cap && s->vstamp[tv2] != s->stamp)
                     { s->vstamp[tv2] = s->stamp; nid++; }
                     if (tr->Layer == 1) rg->flags |= 2;      /* Shape.hidden */
                  }
                  rg->px0 = (int16_t)p0x; rg->py0 = (int16_t)p0y;
                  rg->px1 = (int16_t)p1x; rg->py1 = (int16_t)p1y;
                  rg->tx0 = (int16_t)(minx >> 3); rg->ty0 = (int16_t)(miny >> 3);
                  rg->tw = (uint16_t)rw; rg->th = (uint16_t)rh;
                  rg->idents = (uint16_t)(nid < 65535 ? nid : 65535);
                  rg->pal = scene->Tiles[s->region[0]].Palette;
                  rg->pattern = best;
                  rg->cell_base = base;
                  rg->tile_first = out->rtile_n;
                  rg->tile_count = rn;
                  if (!ra3d_grow((void**)&out->rtile, &out->rtile_cap,
                                 out->rtile_n + rn, sizeof(uint32_t)))
                     return 0;
                  memcpy(out->rtile + out->rtile_n, s->region, (size_t)rn * sizeof(uint32_t));
                  out->rtile_n += rn;
               }
               out->region_count++;

               for (vi = v0; vi < v1; vi++)
               {
               const Ra3dShape3D *sh = pa->shape_count
                                     ? &prof->shapes.v[pa->shape_first + vi] : NULL;
               Ra3dGeoInstance in;
               uint8_t layer;
               float d;
               /* a hidden alternate draws nothing and casts nothing: skip it
                * (index 0 still emits a HIDDEN instance) */
               if (sh && vi > 0 && !k->lua_active && (sh->render_style == 0 || sh->lua_hidden))
               { if (sh->lua_hidden && sh->render_style) out->lua_hidden++; continue; }
               layer = sh ? sh->layer : 2;
               d = sh ? sh->size_z * k->size_z_scale : k->fallback_size_z;
               if (d == 0.0f) d = 1.0f;

               memset(&in, 0, sizeof(in));
               in.pos[0] = (float)minx;
               in.pos[1] = (float)miny;
               in.pos[2] = ra3d_layer_centre_z(prof, k, layer, d);
               in.size[0] = (float)(rw * 8);
               in.size[1] = (float)(rh * 8);
               in.size[2] = d;
               if (sh)
               {
                  out->flattened += ra3d_inst_xform(&in, &out->regions[out->region_count - 1],
                                                    sh->scale, sh->rot, sh->offset, sh->pivot,
                                                    k->unity_frame, flat);
                  in.alpha = sh->alpha;
                  in.geo   = sh->geo;
               }
               else
               {
                  in.scale[0] = in.scale[1] = in.scale[2] = 1.0f;
                  in.pivot[0] = in.pivot[1] = in.pivot[2] = 0.5f;
                  in.alpha = 1.0f; in.geo = 0;
               }
               in.zlayer = layer;
               in.cell_offset = base;
               in.cell_count  = (uint16_t)ncell;
               /* +: a textured Pattern3D draws its
                * texture, on its own copy of the region's cells. Each scene
                * tile draws the texture block at the cell of ITS identity in
                * the pattern (3dSen keys a Pattern3D's meshes by Tile2D and
                * draws one per tile), so a clipped,
                * partial or rearranged region takes the right blocks, and a
                * cell with no scene tile draws nothing. Palettes stay the
                * tiles' own. did this only for a region exactly the
                * texture's size, cell for cell. */
               if (sh && sh->tt_gw && sh->tt_gw == pa->w && sh->tt_gh == pa->h)
               {
                  uint32_t ntt = (uint32_t)pa->w * pa->h;
                  int direct = sh->dtex_w && sh->dtex_w == (uint32_t)pa->w * 8u
                                          && sh->dtex_h == (uint32_t)pa->h * 8u;
                  if (ra3d_grow((void**)&out->cells, &out->cell_cap,
                                out->cell_count + ncell, sizeof(Ra3dGeoCell)))
                  {
                     uint32_t nb = out->cell_count, c2;
                     for (c2 = 0; c2 < ncell; c2++)
                     {
                        Ra3dGeoCell z = out->cells[base + c2];
                        z.chr = RA3D_CELL_EMPTY; z.flip = 0; z.pad = 0;
                        out->cells[nb + c2] = z;
                     }
                     for (c2 = 0; c2 < rn; c2++)
                     {
                        const Ra3dSceneTile *tr = &scene->Tiles[s->region[c2]];
                        int32_t tv = s->tile_var[s->region[c2]];
                        int32_t gx = (tr->X - minx + 4) / 8, gy = (tr->Y - miny + 4) / 8;
                        uint32_t lo = pa->ident_first, hi = pa->ident_first + pa->ident_count, pc, xi;
                        Ra3dGeoCell *z;
                        if (gx < 0 || gy < 0 || (uint32_t)gx >= rw || (uint32_t)gy >= rh) continue;
                        z = &out->cells[nb + (uint32_t)gy * rw + (uint32_t)gx];
                        while (lo < hi)
                        {
                           uint32_t mid = lo + ((hi - lo) >> 1);
                           if (prof->idents.v[mid] < (uint32_t)tv) lo = mid + 1; else hi = mid;
                        }
                        pc = (tv >= 0 && lo < pa->ident_first + pa->ident_count &&
                              prof->idents.v[lo] == (uint32_t)tv) ? prof->identcell.v[lo] : 0xFFFFFFFFu;
                        xi = pc < ntt ? ra3d_frame_tt_tile(out, prof, pa->shape_first + vi, pc) : 0xFFFFFFFFu;
                        if (xi == 0xFFFFFFFFu || atlas + xi >= RA3D_CELL_EMPTY)
                        {  /* not in the pattern (cannot happen for a grown
                            * region) or out of atlas room: the frame's tile */
                           *z = out->cells[base + (uint32_t)gy * rw + (uint32_t)gx];
                           continue;
                        }
                        z->chr  = (uint16_t)(atlas + xi);
                        z->flip = 0;
                        z->pad  = direct ? (uint16_t)(pc + 1u) : 0u;
                     }
                     out->cell_count = nb + ncell;
                     in.cell_offset = nb;
                     /* the authored Direct colours, per
                      * cell from the texture tile in `pad` */
                     if (direct) { in.dtex = sh->dtex_first + 1u; in.dtex_gw = pa->w; }
                  }
               }
               in.pattern = (int32_t)pa->id;
               in.flags = lc ? RA3D_INST_SPRITE | ra3d_sprite_order_flags(scene, s->region, rn)
                             : 0u;
               if (sh)
                  in.flags |= (uint32_t)sh->fill_flags
                           | ((uint32_t)sh->empty_color << RA3D_INST_EMPTY_SHIFT)
                           | ra3d_mode_flags(sh, k);
               if (sh && k->unity_frame)
                  in.flags |= sh->tag_gaxis ? RA3D_INST_ROT_YXZ : RA3D_INST_ROT_XYZ;
               in.flags |= ra3d_shadow_flags(prof, sh, layer, in.alpha);
               if (sh && sh->lua_hidden && !k->lua_active)
               {  /* a linked UpdateS sets Enable = false every frame */
                  in.flags |= RA3D_INST_HIDDEN | RA3D_INST_NOCAST;
                  if (sh->render_style) out->lua_hidden++;
               }
               if (!ra3d_grow((void**)&out->instances, &out->instance_cap,
                              out->instance_count + 1, sizeof(Ra3dGeoInstance)) ||
                   !ra3d_grow((void**)&out->shape_of, &out->shape_of_cap,
                              out->instance_count + 1, sizeof(uint32_t)) ||
                   !ra3d_grow((void**)&out->region_of, &out->region_of_cap,
                              out->instance_count + 1, sizeof(uint32_t)))
                  return 0;
               out->shape_of[out->instance_count] =
                  sh ? pa->shape_first + vi : RA3D_NO_SHAPE;
               out->region_of[out->instance_count] = out->region_count - 1;
               out->instances[out->instance_count++] = in;
               if (vi == v0)
               {
                  out->pattern_instances++;
                  if (ncell > 1) out->multi_tile++;
               }
               else out->variants++;
               }
            }
         }
      }
   }

   /* ---- fallback: one 1x1 slab per unclaimed non-empty cell, in scene order.
    * 3dSen's own generic background pass is a single tile in 3D mode,
    * so this IS that pass. */
   for (t = 0; t < tiles && k->enable_fallback; t++)
   {
      const Ra3dSceneTile *tl = &scene->Tiles[t];
      Ra3dGeoInstance in;
      uint32_t base;
      if (tl->Chr >= atlas || s->atlas_empty[tl->Chr] || s->claimed[t]) continue;
      if (s->drop[t]) continue;           /* culled / overwritten */
      if (!ra3d_grow((void**)&out->cells, &out->cell_cap,
                     out->cell_count + 1, sizeof(Ra3dGeoCell))) return 0;
      base = out->cell_count++;
      out->cells[base].gx = 0; out->cells[base].gy = 0;
      out->cells[base].pal = tl->Palette;
      out->cells[base].flip = (uint8_t)(tl->Flags & 3u);
      out->cells[base].chr = tl->Chr;
      out->cells[base].pad = 0;

      memset(&in, 0, sizeof(in));
      in.pos[0] = (float)tl->X; in.pos[1] = (float)tl->Y;
      in.pos[2] = ra3d_layer_centre_z(prof, k, 2, k->fallback_size_z);   /* fallbacks live on L1 */
      in.size[0] = 8.0f; in.size[1] = 8.0f; in.size[2] = k->fallback_size_z;
      in.scale[0] = in.scale[1] = in.scale[2] = 1.0f;
      in.pivot[0] = in.pivot[1] = in.pivot[2] = 0.5f;
      in.alpha = 1.0f; in.geo = 0; in.zlayer = 2;
      in.cell_offset = base; in.cell_count = 1;
      in.pattern = -1;
      in.flags = RA3D_INST_FALLBACK | (tl->Layer ? RA3D_INST_SPRITE : 0u);
      if (tl->Layer)
         in.flags |= (tl->Layer == 1 ? RA3D_INST_BEHIND : 0u)
                   | ((uint32_t)(tl->Oam & 0x3F) << RA3D_INST_ORDER_SHIFT);
      in.flags |= ra3d_shadow_flags(prof, NULL, 2, 1.0f);   /* a default Pattern3D on L1 */
      if (!ra3d_grow((void**)&out->instances, &out->instance_cap,
                     out->instance_count + 1, sizeof(Ra3dGeoInstance)) ||
          !ra3d_grow((void**)&out->shape_of, &out->shape_of_cap,
                     out->instance_count + 1, sizeof(uint32_t)) ||
          !ra3d_grow((void**)&out->region_of, &out->region_of_cap,
                     out->instance_count + 1, sizeof(uint32_t))) return 0;
      out->shape_of[out->instance_count] = RA3D_NO_SHAPE;
      out->region_of[out->instance_count] = RA3D_NO_SHAPE;
      out->instances[out->instance_count++] = in;
      out->fallbacks++;
   }

   out->covered = 0;
   for (t = 0; t < tiles; t++)
   {
      const Ra3dSceneTile *tl = &scene->Tiles[t];
      if (tl->Chr < atlas && !s->atlas_empty[tl->Chr] && s->claimed[t])
         out->covered++;
   }

   out->match_ms = ra3d_now_ms() - t0;
   return 1;
}

void ra3d_frame_release(Ra3dGeoFrame *f)
{
   Ra3dScratch *s;
   if (!f) return;
   free(f->instances); free(f->cells); free(f->shape_of); free(f->dtex);
   free(f->region_of); free(f->regions); free(f->rtile);
   f->instances = NULL; f->cells = NULL; f->shape_of = NULL;
   f->region_of = NULL; f->regions = NULL; f->rtile = NULL; f->rtile_n = f->rtile_cap = 0;
   f->dtex = NULL; f->dtex_n = f->dtex_cap = f->dtex_serial = 0; f->dtex_gen++;
   free(f->xpx); free(f->tt_gen); free(f->tt_base);
   f->xpx = NULL; f->tt_gen = f->tt_base = NULL;
   f->xpx_n = f->xpx_cap = f->tt_cap = f->tt_stamp = 0;
   f->instance_cap = f->cell_cap = f->shape_of_cap = 0;
   f->region_of_cap = f->region_cap = f->region_count = 0;
   s = (Ra3dScratch*)f->scratch;
   if (s)
   {
      free(s->canon); free(s->atlas_empty); free(s->ahash);
      free(s->var_key); free(s->key_var);
      free(s->phead[0]); free(s->phead[1]); free(s->pnext);
      free(s->tile_var); free(s->nbr); free(s->tile_lc);
      free(s->claimed); free(s->inregion); free(s->drop); free(s->tgx); free(s->tgy);
      free(s->sortk); free(s->ord[0]); free(s->ord[1]);
      free(s->region); free(s->cand); free(s->cand2);
      free(s->rowmin); free(s->rowmax); free(s->colmin); free(s->colmax);
      free(s->occ); free(s->abox); free(s->vstamp);
      free(s);
      f->scratch = NULL;
   }
}

#endif /* RA3D_SHAPE_IMPLEMENTATION */
#endif /* RA3D_SHAPE_H */
