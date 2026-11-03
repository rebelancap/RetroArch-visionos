/* ra3d_vox.h — 3dSen's per-pixel voxel tiles.
 *
 *   #define RA3D_VOX_IMPLEMENTATION
 *   #include "ra3d_vox.h"
 *
 * 3dSen has no extruded primitives: every 8x8 tile is an 8x8xZ VOXEL grid,
 * filled per pattern by its Geo3DType, and each tile is greedy-meshed into
 * boundary faces with flat +-X/+-Y/+-Z normals. Pixels
 * equal to the pattern's emptyColor (colour 0 by default) are EMPTY voxels, so
 * a sprite's outline and every hole in it carry their own side walls.
 *
 * This file is that construction, matched to 3dSen's output (the Default,
 * Cube and [half] cylinder fills, the ellipse rasteriser and the greedy
 * mesher), plus a mesh
 * cache so a steady-state frame does no meshing at all:
 *
 *   - a plain `Default` pattern (no fullWarp) is per-pixel independent, so its
 *     tiles mesh ONCE per (8x8 pixel content, emptyColor) at unit depth and the
 *     instance matrix stretches them to the pattern's depth — one cache entry
 *     serves every copy of that tile at any depth, flip baked into the content;
 *   - every other type fills at PATTERN level (a cylinder's ellipse spans tile
 *     boundaries, CUBE's shell is the region's), so the whole region meshes as
 *     one entry keyed by its full pixel content, type, flags and depth.
 *
 * Merging is 3dSen's default mono GREEDY:
 * any run of solid boundary voxels becomes one quad whose corners carry the
 * corner voxels' PIXEL coordinates (+1 on the far side), and the
 * fragment shader point-samples the NES pixel under the interpolated uv — so a
 * whole 8x8 front face is two triangles yet every pixel keeps its colour. A
 * colour-merged (GREEDY_MULTICOLOR) mesher was tried first and produced 123K
 * vertices for SMB's ground slab alone. Deliberate deviations: the
 * fragment clamps the uv to the quad's own pixel rectangle (no bleed into a
 * neighbour pixel at a quad edge); `fillrate` is always 1 (it is not
 * serialised); the custom texture is not read (the live screen
 * pixels are used).
 *
 * MARCHING is 3dSen's other mesher (the v2
 * "Retina" option, forced per Pattern3D by `rm = 2`): per-colour marching
 * cubes over the voxel grid, vertices on the cube corners, flat normals, one
 * texel per triangle, scaled n/(n+1). It always meshes at pattern level (a
 * cell straddles tile borders). See ra3d_vox_mesh_marching.
 *
 * Header-only and pure C for the same reason as ra3d_geo_gpu.h: the mac
 * preview runs this exact code, and a new .c/.m would edit inside patch 0013's
 * pbxproj hunk.
 */
#ifndef RA3D_VOX_H
#define RA3D_VOX_H

#include <stdint.h>
#include <stddef.h>
#include "ra3d_shape.h"

#ifdef __cplusplus
extern "C" {
#endif

/* One mesh vertex, 32 bytes; must match `VoxVert` in the Metal source.
 *   x, y    NES px from the PIECE origin (+Y down)
 *   z       normalised depth in [-0.5, +0.5], +Z toward the viewer; the
 *           instance matrix scales it to the pattern's depth, so depth is
 *           CENTRED on the tile plane as in 3dSen (Tile3D Center = sizeZ/2)
 *   packed  bits 0-2 normal (0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z, NES world);
 *           bit 3 set (MARCHING only): the normal is instead the
 *           snorm8 x/y/z in bits 8-15/16-23/24-31, in the same unit-box
 *           frame the axis normals are in (bits 0-2 = its dominant axis)
 *   u, v    pixel coordinate in the instance's (flip-applied) image, from the
 *           piece origin — interpolated, then point-sampled
 *   rect    the quad's pixel rectangle [u0, v0, u1, v1), same origin; the
 *           fragment clamps uv inside it */
typedef struct
{
   float    x, y, z;
   uint32_t packed;
   float    u, v;
   uint16_t rect[4];
} Ra3dVoxVert;

/* One draw instance of a cached mesh, 16 bytes; must match `VoxPiece`. */
typedef struct
{
   uint32_t inst;     /* slot in the frame's Ra3dGeoInst array        */
   uint32_t cell;     /* absolute index into the frame's cell array   */
   float    ox, oy;   /* piece origin inside the instance box, NES px */
} Ra3dVoxPiece;

/* One instanced draw: `piece_count` pieces of the mesh at verts[first..). */
typedef struct
{
   uint32_t first, count;          /* into the cache's vertex array */
   uint32_t piece_first, piece_count;
   uint32_t blend;
} Ra3dVoxRun;

typedef struct Ra3dVoxCache Ra3dVoxCache;

Ra3dVoxCache *ra3d_vox_cache_new(void);
void          ra3d_vox_cache_free(Ra3dVoxCache *c);

/* The cache's vertex array. `generation` changes whenever the cache was
 * flushed (verts restarted from 0) — a GPU copy must then be re-uploaded from
 * scratch rather than appended to. */
const Ra3dVoxVert *ra3d_vox_verts(const Ra3dVoxCache *c, uint32_t *count,
                                  uint32_t *generation);

/* Per-frame output, owned by the cache and valid until the next build. */
typedef struct
{
   const Ra3dVoxPiece *pieces;  uint32_t piece_count;
   const Ra3dVoxRun   *runs;    uint32_t run_count;
   uint32_t opaque_runs;        /* runs[0..opaque_runs) opaque, rest blended */
   /* stats for the beacon */
   uint32_t meshed;             /* cache misses this frame (meshes built)    */
   uint32_t hits;               /* cache hits this frame                     */
   uint32_t deferred;           /* region misses pushed to a later frame     */
   uint32_t entries;            /* live cache entries                        */
   uint32_t frame_verts;        /* vertices drawn this frame (all pieces)    */
   uint32_t marching;           /* instances meshed/drawn MARCHING    */
   uint32_t compactions;        /* cache compactions so far (total)   */
   double   mesh_ms;            /* time spent in misses                      */
   double   total_ms;           /* whole ra3d_vox_build                      */
} Ra3dVoxFrame;

/* Builds the frame's pieces. `slot_of[i]` maps frame instance i to its slot in
 * the GPU instance array (ra3d_geo_instances' order). `atlas` is one byte per
 * pixel, 8 wide x 8*atlas_count tall (ra_vision_scene_atlas). */
int ra3d_vox_build(Ra3dVoxCache *c, const Ra3dGeoFrame *g,
                   const uint32_t *slot_of, const uint8_t *atlas,
                   unsigned atlas_count, Ra3dVoxFrame *out);

#ifdef __cplusplus
}
#endif

/* ========================================================================== */
#ifdef RA3D_VOX_IMPLEMENTATION

#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <stdio.h>

#define RA3D_VOX_MAXZ        64u        /* voxel layers for pattern-level fills */
#define RA3D_VOX_FLUSH_VERTS (512u << 10) /* 16 MB of vertices (32 B each): flush */
/* a frame whose own meshes need more than half the flush threshold
 * would flush every frame and remesh forever (MARCHING scenes reach 0.5 M
 * vertices: Punch-Out with retina = 1). The threshold then grows to twice
 * that frame's working set, up to this cap (128 MB). Greedy scenes never
 * get near it, so their behaviour is unchanged. */
#define RA3D_VOX_FLUSH_MAX   (4096u << 10)
#define RA3D_VOX_FLUSH_ENTS  16384u
#define RA3D_VOX_EMPTY       0xFFFFFFFFu
/* Meshing runs on the render thread. Past this much meshing in one frame, an
 * uncached REGION (the only expensive kind) is skipped for this frame and
 * meshed on the next one the emulator produces — a one-frame pop-in for that
 * one shape instead of a dropped compositor frame for everything. */
#define RA3D_VOX_BUDGET_MS   3.0

/* ------------------------------------------------------------------ cache */

typedef struct
{
   uint64_t hash;
   uint32_t key_off, key_len;
   uint32_t first, count;
   uint32_t stamp;              /* last build that drew it */
} Ra3dVoxEntry;

struct Ra3dVoxCache
{
   Ra3dVoxVert  *verts;  uint32_t nverts, cap_verts;
   Ra3dVoxEntry *ents;   uint32_t nents, cap_ents;
   uint8_t      *keys;   uint32_t nkeys, cap_keys;
   uint32_t     *table;  uint32_t table_mask;   /* entry index + 1, 0 = free */
   uint32_t      generation;
   uint32_t      flush_verts;   /* the live threshold (>= the define) */
   uint32_t      stamp;         /* build counter, see ra3d_vox_compact */
   uint32_t      compactions;

   /* per-frame scratch */
   Ra3dVoxPiece *pieces; uint32_t cap_pieces;
   Ra3dVoxPiece *sorted; uint32_t cap_sorted;
   uint64_t     *pkey;   uint32_t cap_pkey;     /* (blend, mesh) << 32 | piece */
   Ra3dVoxRun   *runs;   uint32_t cap_runs;
   uint32_t     *memo;   uint32_t cap_memo;     /* (chr, flip) -> entry + 1 */
   uint8_t      *img;    uint32_t cap_img;      /* region pixels            */
   uint8_t      *present; uint32_t cap_present; /* region tiles present     */
   uint32_t     *vox;    size_t   cap_vox;      /* region voxel uvs         */
   uint8_t      *occ;    size_t   cap_occ;      /* tiles x 3 x MAXZ layers  */
   uint8_t      *touched; uint32_t cap_touched; /* tile block initialised   */
   uint8_t      *key;    uint32_t cap_key;
   /* MARCHING's two corner planes (layers z and z+1), each
    * (W+2) x (H+2): the drawn colour (0 = none) and the voxel uv */
   uint8_t      *mckey;  uint32_t cap_mckey;
   uint32_t     *mcuv;   uint32_t cap_mcuv;
   /* per region tile, its identity's first tile,
    * the identity hashes and an open-addressed table over them */
   uint32_t     *alias;  uint32_t cap_alias;
   uint64_t     *ihash;  uint32_t cap_ihash;
   uint32_t     *itab;   uint32_t cap_itab;
};

static int ra3d_vox_grow(void **p, uint32_t *cap, uint32_t need, size_t esz)
{
   uint32_t n;
   void *np;
   if (need <= *cap) return 1;
   n = *cap ? *cap : 64;
   while (n < need) n *= 2;
   np = realloc(*p, (size_t)n * esz);
   if (!np) return 0;
   *p = np; *cap = n;
   return 1;
}

static uint64_t ra3d_vox_hash(const uint8_t *k, uint32_t n)
{
   uint64_t h = 1469598103934665603ull;
   uint32_t i;
   for (i = 0; i < n; i++) { h ^= k[i]; h *= 1099511628211ull; }
   return h ^ (h >> 29);
}

static void ra3d_vox_flush(Ra3dVoxCache *c)
{
   c->nverts = c->nents = c->nkeys = 0;
   if (c->table) memset(c->table, 0, (size_t)(c->table_mask + 1) * sizeof(uint32_t));
   c->generation++;
}

/* what crossing the threshold does. A full flush drops every mesh, so
 * the next frame re-meshes its whole working set under the 3 ms budget and
 * DEFERS the rest: with MARCHING (`retina = 1`) a big scene (Punch-Out, SMB
 * scrolling) blanked for several frames on every flush, in the simulator. So
 * keep the meshes the last build drew and drop only the rest. Entries are
 * append-only, so live ones move down with memmove (dest <= src). The kept
 * vertex count is that frame's `used`, which the threshold is >= 2x of, so a
 * compaction always frees at least half. A new generation tells the GPU
 * mirror to re-upload. */
static void ra3d_vox_compact(Ra3dVoxCache *c)
{
   uint32_t i, ne = 0, nv = 0, nk = 0;
   for (i = 0; i < c->nents; i++)
   {
      Ra3dVoxEntry en = c->ents[i];
      if (en.stamp != c->stamp || !c->stamp) continue;
      if (en.first != nv && en.count)
         memmove(c->verts + nv, c->verts + en.first, (size_t)en.count * sizeof(Ra3dVoxVert));
      if (en.key_off != nk)
         memmove(c->keys + nk, c->keys + en.key_off, en.key_len);
      en.first = nv; en.key_off = nk;
      nv += en.count; nk += en.key_len;
      c->ents[ne++] = en;
   }
   c->nverts = nv; c->nents = ne; c->nkeys = nk;
   if (c->table) memset(c->table, 0, (size_t)(c->table_mask + 1) * sizeof(uint32_t));
   for (i = 0; i < ne; i++)
   {
      uint32_t slot = (uint32_t)c->ents[i].hash & c->table_mask;
      while (c->table[slot]) slot = (slot + 1) & c->table_mask;
      c->table[slot] = i + 1;
   }
   c->generation++;
   c->compactions++;
}

Ra3dVoxCache *ra3d_vox_cache_new(void)
{
   Ra3dVoxCache *c = (Ra3dVoxCache *)calloc(1, sizeof(*c));
   if (!c) return NULL;
   c->table_mask = 32767;
   c->table = (uint32_t *)calloc(c->table_mask + 1, sizeof(uint32_t));
   if (!c->table) { free(c); return NULL; }
   return c;
}

void ra3d_vox_cache_free(Ra3dVoxCache *c)
{
   if (!c) return;
   free(c->verts); free(c->ents); free(c->keys); free(c->table);
   free(c->pieces); free(c->sorted); free(c->pkey);
   free(c->runs); free(c->memo); free(c->img); free(c->present);
   free(c->vox); free(c->key); free(c->occ); free(c->touched);
   free(c->mckey); free(c->mcuv);
   free(c->alias); free(c->ihash); free(c->itab);
   free(c);
}

const Ra3dVoxVert *ra3d_vox_verts(const Ra3dVoxCache *c, uint32_t *count,
                                  uint32_t *generation)
{
   if (count)      *count      = c ? c->nverts : 0;
   if (generation) *generation = c ? c->generation : 0;
   return c ? c->verts : NULL;
}

/* Returns entry index + 1, or 0. */
static uint32_t ra3d_vox_find(const Ra3dVoxCache *c, const uint8_t *k,
                              uint32_t n, uint64_t h)
{
   uint32_t slot = (uint32_t)h & c->table_mask;
   for (;;)
   {
      uint32_t e = c->table[slot];
      if (!e) return 0;
      {
         const Ra3dVoxEntry *en = &c->ents[e - 1];
         if (en->hash == h && en->key_len == n &&
             memcmp(c->keys + en->key_off, k, n) == 0)
            return e;
      }
      slot = (slot + 1) & c->table_mask;
   }
}

/* ------------------------------------------------- the voxel grid (per tile)
 * 3dSen's Tile3D.pixelUV: per voxel, per AXIS, the source pixel whose colour
 * that axis's faces show — or empty. Stored as (x | y << 16), region pixel
 * coordinates, RA3D_VOX_EMPTY for empty. One 8x8xZx3 block per present tile,
 * tiles laid out row-major over the region grid. */
typedef struct
{
   uint32_t      *vox;
   const uint8_t *img;       /* region pixels, W x H, value 0..3 */
   const uint8_t *present;   /* gw x gh */
   int            W, H, gw, gh, Z;
   int            empty;     /* emptyColor */
   int            solid, fullWarp, antiShadow;
   /* MARCHING keeps ONE uv per voxel (as 3dSen does: one uv slot,
    * the axis ignored): every write lands on all
    * three axis slots, last write wins, the mesher reads slot 0. */
   int            marching;
   /* every voxel column is uniform along z (plain Default, no
    * fullWarp): the marching mesher then emits the interior layers once,
    * stretched (an exact union of the same coplanar triangles) */
   int            zext;
   /* Per tile: `touched` says the tile's voxel block has been cleared (it is
    * cleared lazily on first write, so an untouched tile costs nothing), and
    * occ[tile][axis][layer] whether any voxel in that layer carries an
    * axis-d uv — kept at write time so the mesher skips empty slices without
    * scanning the block (measurement). */
   uint8_t       *touched;
   uint8_t       *occ;
   /* Pattern3D.tile3DGrid. 3dSen keeps ONE Tile3D per distinct Tile2D
    * (raw CHR + flip) in a pattern, so every fill write to any cell of that
    * identity lands in the same voxel block, and every such cell draws it.
    * alias[t] is the region tile whose block cell t reads and writes (the
    * first cell of its identity); NULL = every cell its own block. */
   const uint32_t *alias;
} Ra3dVoxGrid;

static int ra3d_vox_canon(const Ra3dVoxGrid *g, int tile)
{
   return g->alias ? (int)g->alias[tile] : tile;
}

static int ra3d_vox_px(const Ra3dVoxGrid *g, int x, int y)
{
   /* texture reads wrap (x %= w); keep it non-negative in C */
   x %= g->W; if (x < 0) x += g->W;
   y %= g->H; if (y < 0) y += g->H;
   return g->img[(size_t)y * g->W + x];
}

static size_t ra3d_vox_at(const Ra3dVoxGrid *g, int tile, int lx, int ly, int z, int d)
{
   return ((((size_t)tile * g->Z + z) * 8 + ly) * 8 + lx) * 3 + d;
}

/* set one voxel's uv. Out-of-grid writes are dropped (nothing on screen
 * depends on them). */
static void ra3d_vox_set(Ra3dVoxGrid *g, int x, int y, int z, int ux, int uy, int d)
{
   int tile, i;
   uint32_t v;
   if (x < 0 || y < 0 || x >= g->W || y >= g->H || z < 0 || z >= g->Z) return;
   if (g->marching) d = -1;   /* one uv per voxel */
   tile = (y >> 3) * g->gw + (x >> 3);
   if (!g->present[tile]) return;
   tile = ra3d_vox_canon(g, tile);   /* the identity's shared block */
   /* store the pixel actually sampled (GetPixel wraps) so the uv is in range */
   ux %= g->W; if (ux < 0) ux += g->W;
   uy %= g->H; if (uy < 0) uy += g->H;
   v = (ra3d_vox_px(g, ux, uy) == g->empty) ? RA3D_VOX_EMPTY
     : ((uint32_t)(ux & 0xFFFF) | ((uint32_t)(uy & 0xFFFF) << 16));
   if (!g->touched[tile])
   {
      memset(&g->vox[ra3d_vox_at(g, tile, 0, 0, 0, 0)], 0xFF,
             (size_t)64 * g->Z * 3 * sizeof(uint32_t));
      memset(&g->occ[(size_t)tile * 3 * RA3D_VOX_MAXZ], 0, 3 * RA3D_VOX_MAXZ);
      g->touched[tile] = 1;
   }
   for (i = 0; i < 3; i++)
   {
      if (d != -1 && i != d) continue;
      g->vox[ra3d_vox_at(g, tile, x & 7, y & 7, z, i)] = v;
      if (v != RA3D_VOX_EMPTY)
      {
         int layer = (i == 0) ? (x & 7) : (i == 1) ? (y & 7) : z;
         g->occ[((size_t)tile * 3 + i) * RA3D_VOX_MAXZ + layer] = 1;
      }
   }
}

/* --------------------------------------------------- Pattern3D fill rules */

typedef void (*ra3d_vox_plot_fn)(void *ud, int a, int b);

static void ra3d_vox_drawline(int x0, int y0, int x1, int y1, float fillrate,
                              ra3d_vox_plot_fn plot, void *ud)
{
   int steep = abs(y1 - y0) > abs(x1 - x0), t, num, num2, num3, num4, num5, num6, i;
   if (steep) { t = x0; x0 = y0; y0 = t; t = x1; x1 = y1; y1 = t; }
   num = x1;
   if (x0 > x1) { t = x0; x0 = x1; x1 = t; t = y0; y0 = y1; y1 = t; num = x0; }
   num2 = x1 - x0;
   num3 = abs(y1 - y0);
   num4 = num2 / 2;
   num5 = (y0 < y1) ? 1 : -1;
   num6 = y0;
   for (i = x0; i <= x1; i++)
   {
      if ((float)abs(i - num) / (float)num2 < fillrate)
      {
         if (steep) plot(ud, num6, i); else plot(ud, i, num6);
      }
      num4 -= num3;
      if (num4 < 0) { num6 += num5; num4 += num2; }
   }
}

typedef struct
{
   Ra3dVoxGrid *g;
   int h, dir, x0, y0, quarters;
   int color[4];
   int uvx[4], uvy[4];
} Ra3dVoxEll;

static void ra3d_vox_ell_plot(void *ud, int a, int b)
{
   Ra3dVoxEll *e = (Ra3dVoxEll *)ud;
   /* dir 0: SetUV(a, h, b, ..); dir 1: SetUV(h, a, b, ..) — the four mirrored
    * quarters of the ellipse's line callback */
   int pa[4], pb[4], j;
   pa[0] = a;          pb[0] = b;
   pa[1] = a;          pb[1] = e->y0 - b;
   pa[2] = e->x0 - a;  pb[2] = b;
   pa[3] = e->x0 - a;  pb[3] = e->y0 - b;
   for (j = 0; j < 4; j++)
   {
      if (!(e->quarters & (1 << j)) || e->color[j] == 0) continue;
      if (e->dir == 0) ra3d_vox_set(e->g, pa[j], e->h, pb[j], e->uvx[j], e->uvy[j], -1);
      else             ra3d_vox_set(e->g, e->h, pa[j], pb[j], e->uvx[j], e->uvy[j], -1);
   }
}

/* The ellipse rasteriser 3dSen's cylinders are built with (fillrate = 1). Coordinates are
 * DOUBLED: x0 is the run's start+end, y0 is sizeZ-1, dx/dy the doubled radii. */
static void ra3d_vox_ellipse(Ra3dVoxGrid *g, int x0, int y0, int dx, int dy,
                             int h, int dir, int dq)
{
   int num = 2 * dx * dx, num2 = 2 * dy * dy;
   int num3 = dx * dx * dy, num4 = 0, num5 = dy, num6 = 0, num7 = num * dy;
   int ax[4], ay[4], az[4];
   Ra3dVoxEll e;
   int pass, i;

   memset(&e, 0, sizeof(e));
   e.g = g; e.h = h; e.dir = dir; e.x0 = x0; e.y0 = y0; e.quarters = dq;

   if (dx == 0 || dy == 0)
   {
      if (dir == 0) ra3d_vox_set(g, x0 >> 1, h, y0 >> 1, x0 >> 1, h, -1);
      else          ra3d_vox_set(g, h, x0 >> 1, y0 >> 1, h, x0 >> 1, -1);
      return;
   }

   for (pass = 0; pass < 2; pass++)
   {
      if (pass == 1)
      { num3 = dy * dy * dx; num4 = dx; num5 = 0; num6 = num2 * dx; num7 = 0; }
      while (pass == 0 ? (num6 <= num7) : (num6 >= num7))
      {
         int num8  = (x0 + num4) >> 1;
         int num9  = x0 - num8;
         int num10 = (pass == 0) ? ((y0 + num5) >> 1) : ((y0 + num5 - 1) >> 1);
         int num11 = y0 - num10;
         int u0, u1;
         if (pass == 1 && g->antiShadow)
         {
            u0 = ((dq & 0xC) == 12) ? ((x0 - num5 + 1) >> 1) : ((x0 + num5) >> 1);
            u1 = ((dq & 3) == 3)    ? ((x0 + num5) >> 1)     : ((x0 - num5 + 1) >> 1);
         }
         else
         {
            u0 = ((dq & 0xC) == 12) ? num9 : num8;
            u1 = ((dq & 3) == 3)    ? num8 : num9;
         }
         if (dir == 0)
         {
            e.uvx[0] = u0; e.uvy[0] = h; e.uvx[1] = u1; e.uvy[1] = h;
            ax[0] = num8; ay[0] = h; az[0] = num10;
            ax[1] = num8; ay[1] = h; az[1] = num11;
            ax[2] = num9; ay[2] = h; az[2] = num10;
            ax[3] = num9; ay[3] = h; az[3] = num11;
         }
         else
         {
            e.uvx[0] = h; e.uvy[0] = u0; e.uvx[1] = h; e.uvy[1] = u1;
            ax[0] = h; ay[0] = num8; az[0] = num10;
            ax[1] = h; ay[1] = num8; az[1] = num11;
            ax[2] = h; ay[2] = num9; az[2] = num10;
            ax[3] = h; ay[3] = num9; az[3] = num11;
         }
         e.uvx[2] = e.uvx[1]; e.uvy[2] = e.uvy[1];
         e.uvx[3] = e.uvx[0]; e.uvy[3] = e.uvy[0];
         for (i = 0; i < 4; i++) e.color[i] = ra3d_vox_px(g, e.uvx[i], e.uvy[i]);

         if (!g->solid)
         {
            for (i = 0; i < 4; i++)
               if ((dq & (1 << i)) && e.color[i] != 0)
                  ra3d_vox_set(g, ax[i], ay[i], az[i], e.uvx[i], e.uvy[i], -1);
         }
         else if (!g->fullWarp)
            ra3d_vox_drawline(x0 >> 1, y0 >> 1, num8, num10, 1.0f,
                              ra3d_vox_ell_plot, &e);
         else
         {
            int z;
            for (z = num11; z <= num10; z++)
            {
               if ((dq & 3) == 3)
                  ra3d_vox_set(g, ax[0], ay[0], z, e.uvx[2], e.uvy[2], -1);
               if ((dq & 0xC) == 12)
                  ra3d_vox_set(g, ax[2], ay[2], z, e.uvx[0], e.uvy[0], -1);
            }
         }

         if (pass == 0)
         {
            num4++;
            num3 -= num2 * (num4 - 1);
            num6 += num2;
            if (num3 <= 0) { num3 += num * (num5 - 1); num5--; num7 -= num; }
         }
         else
         {
            num5++;
            num3 -= num * (num5 - 1);
            num7 += num;
            if (num3 < 0) { num3 += num2 * (num4 - 1); num4--; num6 -= num2; }
         }
      }
   }
}

/* H/V cylinders and the half variants. `vertical` selects the run
 * axis (HCYLINDER runs down columns, VCYLINDER along rows); `half` the
 * half-cylinder anchoring. */
static void ra3d_vox_cylinder(Ra3dVoxGrid *g, int along_y, int half, int flip)
{
   int outer = along_y ? g->W : g->H;
   int inner = along_y ? g->H : g->W;
   int i, j;
   for (i = 0; i < outer; i++)
      for (j = 0; j < inner; j++)
      {
         int px = along_y ? ra3d_vox_px(g, i, j) : ra3d_vox_px(g, j, i);
         int k, rz;
         if (px == g->empty) continue;
         k = j;
         do { k++; }
         while (k < inner && (along_y ? ra3d_vox_px(g, i, k) : ra3d_vox_px(g, k, i)) != g->empty);
         k--;
         if (!half)
         {
            rz = (g->Z - 1 < k - j) ? g->Z - 1 : k - j;
            ra3d_vox_ellipse(g, k + j, g->Z - 1, k - j, rz, i, along_y ? 1 : 0, 15);
         }
         else
         {
            rz = (g->Z - 1 < (k - j) * 2) ? g->Z - 1 : (k - j) * 2;
            if (along_y)   /* BuildHalfHCylinderModel */
               ra3d_vox_ellipse(g, flip ? j * 2 : k * 2, g->Z - 1, (k - j) * 2, rz,
                                i, 1, flip ? 3 : 12);
            else           /* half V cylinder         */
               ra3d_vox_ellipse(g, flip ? k * 2 : j * 2, g->Z - 1, (k - j) * 2, rz,
                                i, 0, flip ? 12 : 3);
         }
         j = k;
      }
}

static void ra3d_vox_cube(Ra3dVoxGrid *g)
{
   int W = g->W, H = g->H, Z = g->Z, i, j;
   for (i = 0; i < W; i++)
      for (j = 0; j < Z; j++)
      {
         ra3d_vox_set(g, i, H - 1, j, i, j, 1);
         ra3d_vox_set(g, i, 0, j, i, Z - 1 - j, 1);
      }
   for (i = 0; i < H; i++)
      for (j = 0; j < Z; j++)
      {
         ra3d_vox_set(g, 0, i, j, Z - 1 - j, i, 0);
         ra3d_vox_set(g, W - 1, i, j, Z - 1 - j, i, 0);
      }
   for (i = 0; i < W; i++)
      for (j = 0; j < H; j++)
      {
         ra3d_vox_set(g, i, j, Z - 1, i, j, 2);
         ra3d_vox_set(g, i, j, 0, i, j, 2);
      }
}

static void ra3d_vox_default(Ra3dVoxGrid *g)
{
   int i, j, k;
   for (i = 0; i < g->W; i++)
      for (j = 0; j < g->H; j++)
      {
         if (ra3d_vox_px(g, i, j) == g->empty) continue;
         for (k = 0; k < g->Z; k++)
         {
            if (g->fullWarp && g->marching)
            {
               /* the Default fill under MARCHING — layer k of
                * column (i, j) shows the pixel k rows further down, walked
                * back up to the nearest solid one (it cannot pass row j) */
               int m = j + k;
               while (ra3d_vox_px(g, i, m) == g->empty) m--;
               ra3d_vox_set(g, i, j, k, i, m, -1);
            }
            else if (g->fullWarp)
            {
               ra3d_vox_set(g, i, j, k, i, g->Z - 1 - k, 1);
               ra3d_vox_set(g, i, j, k, g->Z - 1 - k, j, 0);
               ra3d_vox_set(g, i, j, k, i, j, 2);
            }
            else
               ra3d_vox_set(g, i, j, k, i, j, -1);
         }
      }
}

/* ------------------------------------------------- greedy mesher
 * Per TILE (3dSen meshes each Tile3D separately; faces on a tile border are
 * emitted even when the neighbour tile is solid, exactly as there). Mono
 * merge: any solid boundary voxel joins; a face shows the SOLID voxel's uv on
 * that axis. Index space is 3dSen's: x right, y down (NES), z from the FRONT
 * (z = 0 nearest the viewer). Output is NES world: z flipped so +Z is toward
 * the viewer, normalised by Z, centred. */

/* Per uv component, the value at the quad's four corners (cu, cv in {0,1}),
 * from the four corner VOXELS a (start), b (end along u), c (end along v):
 * 3dSen's rule — the far side of an increasing run gets +1, and a
 * component constant over the whole quad sits mid-pixel. */
static void ra3d_vox_corner_uv(int a, int b, int c, float out[4])
{
   /* out[cu + 2*cv] */
   if (b != a)
   {
      float lo = (b > a) ? (float)a : (float)a + 1.0f;
      float hi = (b > a) ? (float)b + 1.0f : (float)b;
      out[0] = out[2] = lo; out[1] = out[3] = hi;
   }
   else if (c != a)
   {
      float lo = (c > a) ? (float)a : (float)a + 1.0f;
      float hi = (c > a) ? (float)c + 1.0f : (float)c;
      out[0] = out[1] = lo; out[2] = out[3] = hi;
   }
   else
      out[0] = out[1] = out[2] = out[3] = (float)a + 0.5f;
}

static int ra3d_vox_mesh_tile(Ra3dVoxCache *c, const Ra3dVoxGrid *g, int tile,
                              float ox, float oy)
{
   int dims[3] = { 8, 8, g->Z };
   uint32_t mask[8 * RA3D_VOX_MAXZ];     /* largest slice is 8 x Z */
   /* A slice whose two neighbouring layers are both empty on axis d has no
    * faces — most of a CUBE shell, and all of an untouched tile. */
   const uint8_t *occ;
   int d, side;

   tile = ra3d_vox_canon(g, tile);   /* drawn at (ox, oy), shared block */
   occ = &g->occ[(size_t)tile * 3 * RA3D_VOX_MAXZ];

   if (!g->touched[tile]) return 1;

   for (d = 0; d < 3; d++)
   {
      int u = (d + 1) % 3, v = (d + 2) % 3;
      for (side = 0; side < 2; side++)    /* 0: -axis faces, 1: +axis faces */
      {
         int x[3], q[3] = { 0, 0, 0 };
         q[d] = 1;
         for (x[d] = -1; x[d] < dims[d]; )
         {
            int n = 0, i, j;
            /* +faces come from layer x[d], -faces from layer x[d]+1 */
            int src = side ? x[d] : x[d] + 1;
            if (src < 0 || src >= dims[d] || !occ[d * RA3D_VOX_MAXZ + src])
            { x[d]++; continue; }
            for (x[v] = 0; x[v] < dims[v]; x[v]++)
               for (x[u] = 0; x[u] < dims[u]; x[u]++)
               {
                  uint32_t a = (x[d] >= 0)
                     ? g->vox[ra3d_vox_at(g, tile, x[0], x[1], x[2], d)] : RA3D_VOX_EMPTY;
                  uint32_t b = (x[d] + 1 < dims[d])
                     ? g->vox[ra3d_vox_at(g, tile, x[0] + q[0], x[1] + q[1], x[2] + q[2], d)]
                     : RA3D_VOX_EMPTY;
                  mask[n++] = (a == RA3D_VOX_EMPTY || b == RA3D_VOX_EMPTY)
                            ? (side ? a : b)     /* +face: solid A; -face: solid B */
                            : RA3D_VOX_EMPTY;
               }
            x[d]++;
            n = 0;
            for (j = 0; j < dims[v]; j++)
               for (i = 0; i < dims[u]; )
               {
                  int w, h, k, l, done = 0;
                  if (mask[n] == RA3D_VOX_EMPTY) { i++; n++; continue; }
                  for (w = 1; i + w < dims[u] && mask[n + w] != RA3D_VOX_EMPTY; w++) {}
                  for (h = 1; j + h < dims[v] && !done; h++)
                     for (k = 0; k < w; k++)
                        if (mask[n + k + h * dims[u]] == RA3D_VOX_EMPTY) { done = 1; break; }
                  if (done) h--;
                  {
                     /* the quad: plane x[d], spanning [i, i+w) x [j, j+h) */
                     uint32_t va = mask[n], vb = mask[n + w - 1];
                     uint32_t vc = mask[n + (h - 1) * dims[u]];
                     float cu_[4], cv_[4], p[4][3];
                     float r0, r1, r2, r3;
                     int  cc, ni;
                     static const int cu[4] = { 0, 1, 0, 1 }, cv[4] = { 0, 0, 1, 1 };
                     static const int tri[6] = { 0, 1, 3, 0, 3, 2 };
                     ra3d_vox_corner_uv((int)(va & 0xFFFF), (int)(vb & 0xFFFF),
                                        (int)(vc & 0xFFFF), cu_);
                     ra3d_vox_corner_uv((int)(va >> 16), (int)(vb >> 16),
                                        (int)(vc >> 16), cv_);
                     r0 = floorf(fminf(fminf(cu_[0], cu_[1]), fminf(cu_[2], cu_[3])));
                     r2 = ceilf (fmaxf(fmaxf(cu_[0], cu_[1]), fmaxf(cu_[2], cu_[3])));
                     r1 = floorf(fminf(fminf(cv_[0], cv_[1]), fminf(cv_[2], cv_[3])));
                     r3 = ceilf (fmaxf(fmaxf(cv_[0], cv_[1]), fmaxf(cv_[2], cv_[3])));
                     for (cc = 0; cc < 4; cc++)
                     {
                        int pos[3];
                        pos[d] = x[d];
                        pos[u] = i + cu[cc] * w;
                        pos[v] = j + cv[cc] * h;
                        p[cc][0] = ox + (float)pos[0];
                        p[cc][1] = oy + (float)pos[1];
                        p[cc][2] = ((float)g->Z * 0.5f - (float)pos[2]) / (float)g->Z;
                     }
                     /* normal in NES world: X, Y as indexed; Z flipped */
                     if (d == 0)      ni = side ? 0 : 1;
                     else if (d == 1) ni = side ? 2 : 3;
                     else             ni = side ? 5 : 4;
                     if (!ra3d_vox_grow((void **)&c->verts, &c->cap_verts,
                                        c->nverts + 6, sizeof(Ra3dVoxVert)))
                        return 0;
                     for (cc = 0; cc < 6; cc++)
                     {
                        Ra3dVoxVert *vv = &c->verts[c->nverts++];
                        int t = tri[cc];
                        vv->x = p[t][0]; vv->y = p[t][1]; vv->z = p[t][2];
                        vv->packed = (uint32_t)ni;
                        /* uv/rect relative to the piece origin, like x, y */
                        vv->u = cu_[t]; vv->v = cv_[t];
                        vv->rect[0] = (uint16_t)r0; vv->rect[1] = (uint16_t)r1;
                        vv->rect[2] = (uint16_t)r2; vv->rect[3] = (uint16_t)r3;
                     }
                  }
                  for (l = 0; l < h; l++)
                     for (k = 0; k < w; k++)
                        mask[n + k + l * dims[u]] = RA3D_VOX_EMPTY;
                  i += w; n += w;
               }
         }
      }
   }
   return 1;
}

/* ------------------------------------------------ MARCHING
 * 3dSen's MARCHING mesher (the v2 UI calls it
 * "Retina"). Classic marching cubes over the voxel CENTRES, run once per
 * distinct colour in a cell: a corner is "inside" for colour c when its voxel
 * shows c. What makes it 3dSen's look rather than a smooth isosurface:
 *
 *   - a crossed edge's vertex is its OUTSIDE corner (Tile3D.InterpVertex
 *     returns the corner that is not set; its midpoint branch is unreachable
 *     for a crossed edge), so every silhouette step is a 45-degree chamfer
 *     through the neighbouring empty voxel centres and a run of n voxels
 *     spans n + 1;
 *   - the renderer scales the shape by n/(n+1) per axis,
 *     which brings that run back to n voxels — baked into the vertices here;
 *   - flat normals, one per triangle; ONE texel per triangle: the uv of the
 *     LAST corner (in corner order) that shows the colour, sampled mid-texel;
 *   - two colours that meet both mesh up to each other's voxel centres, so a
 *     colour border is a small ridge, as in 3dSen.
 *
 * Corner order and the edge list are Paul Bourke's ("Polygonising a scalar
 * field", 1994): corners 0-3 the y=0 face, 4-7 the y=1 face, edges 0-3 / 4-7
 * around those faces and 8-11 the uprights. With x right, y UP and z = the
 * voxel layer (0 nearest the viewer) — 3dSen's Tile3D index frame, kept so
 * the ambiguous cases split the way they do there. The triangle table is
 * Bourke's public-domain table (Cory Gene Bloyd's), one string per corner
 * mask with each hex digit an edge; it was checked entry by entry against
 * the one 3dSen ships, and the edge-crossing table is derived from the edge
 * list rather than tabulated. */
static const signed char ra3d_mc_corner[8][3] =
{
   { 0, 0, 1 }, { 1, 0, 1 }, { 1, 0, 0 }, { 0, 0, 0 },
   { 0, 1, 1 }, { 1, 1, 1 }, { 1, 1, 0 }, { 0, 1, 0 }
};
static const unsigned char ra3d_mc_edge[12][2] =
{
   { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 }, { 4, 5 }, { 5, 6 },
   { 6, 7 }, { 7, 4 }, { 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }
};
static const char *const ra3d_mc_tri[256] =
{
   "", "083", "019", "183981", "12a", "08312a", "92a029", "2832a8a98",
   "3b2", "0b28b0", "19023b", "1b219b98b", "3a1ba3", "0a108a8ba", "3903b9ba9", "98aa8b",
   "478", "430734", "019847", "419471731", "12a847", "34730412a", "92a902847", "2a9297273794",
   "8473b2", "b47b24204", "90184723b", "47b94b9b2921", "3a13ba784", "1ba14b1047b4", "47890b9bab03", "47b4b99ba",
   "954", "954083", "054150", "854835315", "12a954", "30812a495", "52a542402", "2a5325354348",
   "95423b", "0b208b495", "05401523b", "21525828b485", "a3ba13954", "4950818a18ba", "54050b5bab03", "54858aa8b",
   "978579", "930953573", "078017157", "153357", "978957a12", "a12950530573", "802825857a52", "2a5253357",
   "7957893b2", "95797292027b", "23b018178157", "b21b17715", "958857a13a3b", "5705097b010aba0", "ba0b03a50807570", "ba57b5",
   "a65", "0835a6", "9015a6", "1831985a6", "165261", "165126308", "965906026", "598582526328",
   "23ba65", "b08b20a65", "01923b5a6", "5a61929b298b", "63b653513", "08b0b50515b6", "3b6036065059", "65969bb98",
   "5a6478", "43047365a", "1905a6847", "a65197173794", "612651478", "125526304347", "847905065026", "739794329596269",
   "3b2784a65", "5a647242027b", "01947823b5a6", "9219b294b7b45a6", "8473b53515b6", "51b5b610b7b404b", "059065036b63847", "65969b4797b9",
   "a4964a", "4a649a083", "a01a60640", "83181686461a", "149124264", "308129249264", "024426", "832824426",
   "a49a64b23", "08228b49a4a6", "3b201606461a", "64161a48121b8b1", "964936913b63", "8b1810b61914641", "3b6360064", "648b68",
   "7a678a89a", "0730a709a67a", "a671a7178180", "a67a71173", "126168189867", "269291679093739", "780706602", "732672",
   "23ba68a89867", "20727b09767a9a7", "1801781a767a23b", "b21b17a61671", "896867916b63136", "091b67", "7807063b0b60", "7b6",
   "76b", "308b76", "019b76", "819831b76", "a126b7", "12a3086b7", "2902a96b7", "6b72a3a83a98",
   "723627", "708760620", "276237019", "162186198876", "a76a17137", "a7617a187108", "03707a0a96a7", "76a7a88a9",
   "684b86", "36b306046", "86b846901", "946963931b36", "6846b82a1", "12a30b06b046", "4b846b0292a9", "a93a32943b36463",
   "823842462", "042462", "190234246438", "194142246", "8138618466a1", "a10a06604", "4634386a3039a93", "a946a4",
   "49576b", "083495b76", "50154076b", "b76834354315", "954a1276b", "6b712a083495", "76b54a42a402", "348354325a52b76",
   "723762549", "954086062687", "362376150540", "628687218485158", "954a16176137", "16a176107870954", "40a4a503a6a737a", "76a7a854a48a",
   "6956b9b89", "36b063056095", "0b805b01556b", "6b3635531", "12a95b9b8b56", "0b306b09656912a", "b85b56805a52025", "6b36352a3a53",
   "589528562382", "956960062", "158180568382628", "156216", "13616a386569896", "a10a06950560", "03856a", "a56",
   "b5a75b", "b5ab75830", "5b75ab190", "a75ab7981831", "b12b71751", "08312717572b", "9759279022b7", "75272b592328982",
   "25a235375", "820852875a25", "9015a35373a2", "982921872a25752", "135375", "087071175", "903935537", "987597",
   "5845a8ab8", "5045b05abb30", "01984a8aba45", "ab4a45b34941314", "2512852b8458", "04b0b345b2b151b", "0250592b5458b85", "9452b3",
   "25a352345384", "5a2524420", "3a235a385458019", "5a2524192942", "845853351", "045105", "845853905035", "945",
   "4b749b9ab", "0834979b79ab", "1ab1b414074b", "3143481a474bab4", "4b79b492b912", "9749b791b2b1083", "b74b42240", "b74b42834324",
   "29a279237749", "9a7974a27870207", "37a3a274a1a040a", "1a2874", "491417713", "491417081871", "403743", "487",
   "9a8ab8", "30939bb9a", "01a0a88ab", "31ab3a", "12b1b99b8", "30939b1292b9", "02b80b", "32b",
   "23828aa89", "9a2092", "23828a0181a8", "1a2", "138918", "091", "038", "",
};

/* The voxel uv at region pixel (x, y), layer z, or RA3D_VOX_EMPTY outside
 * the grid or in an absent tile (Tile3D._GetPatternUV). */
static uint32_t ra3d_vox_mc_uv(const Ra3dVoxGrid *g, int x, int y, int z)
{
   int tile;
   if (x < 0 || y < 0 || x >= g->W || y >= g->H || z < 0 || z >= g->Z)
      return RA3D_VOX_EMPTY;
   tile = (y >> 3) * g->gw + (x >> 3);
   if (!g->present[tile]) return RA3D_VOX_EMPTY;
   tile = ra3d_vox_canon(g, tile);
   if (!g->touched[tile]) return RA3D_VOX_EMPTY;
   return g->vox[ra3d_vox_at(g, tile, x & 7, y & 7, z, 0)];
}

static int8_t ra3d_vox_snorm8(float f)
{
   float r = f * 127.0f;
   r = r < -127.0f ? -127.0f : r > 127.0f ? 127.0f : r;
   return (int8_t)lroundf(r);
}

/* One plane of corners (layer z, every x in -1..W, y in -1..H) into
 * key/uv: the colour a corner meshes as (0 = none) and its voxel uv. */
static void ra3d_vox_mc_plane(const Ra3dVoxGrid *g, int z, uint8_t *key, uint32_t *uv)
{
   const int W2 = g->W + 2;
   int x, y;
   for (y = -1; y <= g->H; y++)
      for (x = -1; x <= g->W; x++)
      {
         uint32_t u = ra3d_vox_mc_uv(g, x, y, z);
         /* Tile3D._GetColor: an empty uv reads as colour 0. The colours to
          * mesh are not emptyColor (3dSen's list filter) and not 0 — with
          * emptyColor 0 a 0 is always an empty corner; with any other
          * emptyColor 3dSen meshes 0 together with the outside, whose only
          * triangles face INTO the other colours and are back-face culled
          * there (deviation 3) */
         int k = (u == RA3D_VOX_EMPTY) ? 0
               : ra3d_vox_px(g, (int)(u & 0xFFFF), (int)(u >> 16));
         size_t i = (size_t)(y + 1) * W2 + (x + 1);
         key[i] = (uint8_t)((k == g->empty) ? 0 : k);
         uv[i]  = u;
      }
}

/* Meshes the whole region (MARCHING always works at pattern level: a cell
 * straddles tile borders, and 3dSen reads its neighbours through the
 * pattern). The cell domain is every cell that touches the grid — corners
 * -1..W, -1..H, -1..Z — which is exactly the union of 3dSen's per-tile
 * domains for a full tile grid (deviation 2 for the rest). */
static int ra3d_vox_mesh_marching(Ra3dVoxCache *c, const Ra3dVoxGrid *g)
{
   const int W = g->W, H = g->H, Z = g->Z, W2 = W + 2;
   const uint32_t plane = (uint32_t)(W + 2) * (uint32_t)(H + 2);
   const float hz = 0.5f * (float)Z;
   float sx, sy, px0, py0, fx, fy;
   int cx, cy, cz, stretch;
   uint8_t *kp[2];
   uint32_t *up[2];

   if (!ra3d_vox_grow((void **)&c->mckey, &c->cap_mckey, plane * 2, 1) ||
       !ra3d_vox_grow((void **)&c->mcuv, &c->cap_mcuv, plane * 2, sizeof(uint32_t)))
      return 0;
   /* 3dSen scales the shape by size/(size+1) per axis, size being
    * the shape's TIGHT pixel box (the
    * union of its Tile2Ds' opaque extents; a blank tile contributes start 7 /
    * end 0, as Tile2D.LoadRaw leaves it) by sizeZ, about the shape's Pos —
    * for the default pivot, lerp(BottomLeft, TopRight, 0.5), whose corners
    * are the first and LAST pixels' left/top edges, i.e. the box centre less
    * half a pixel in x and y. Taken from the region's own (flip-applied)
    * pixels, so it is a function of the cache key. */
   {
      int t, x0 = 0x7FFF, y0 = 0x7FFF, x1 = -1, y1 = -1;
      for (t = 0; t < g->gw * g->gh; t++)
      {
         int tx = (t % g->gw) * 8, ty = (t / g->gw) * 8, x, y;
         int sx0 = 7, sy0 = 7, ex = 0, ey = 0;
         if (!g->present[t]) continue;
         for (y = 0; y < 8; y++)
            for (x = 0; x < 8; x++)
               if (g->img[(size_t)(ty + y) * W + tx + x] & 3)
               {
                  if (x < sx0) sx0 = x;
                  if (y < sy0) sy0 = y;
                  if (x > ex) ex = x;
                  if (y > ey) ey = y;
               }
         if (tx + sx0 < x0) x0 = tx + sx0;
         if (ty + sy0 < y0) y0 = ty + sy0;
         if (tx + ex > x1) x1 = tx + ex;
         if (ty + ey > y1) y1 = ty + ey;
      }
      if (x1 < x0 || y1 < y0) { x0 = 0; y0 = 0; x1 = W - 1; y1 = H - 1; }
      sx = (float)(x1 - x0 + 1) / (float)(x1 - x0 + 2);
      sy = (float)(y1 - y0 + 1) / (float)(y1 - y0 + 2);
      px0 = 0.5f * (float)(x0 + x1);
      py0 = 0.5f * (float)(y0 + y1);
      /* a normal is a covector: it scales by the inverse of du/dvoxel */
      fx = (float)W / sx;
      fy = (float)H / sy;
   }
   kp[0] = c->mckey; kp[1] = c->mckey + plane;
   up[0] = c->mcuv;  up[1] = c->mcuv + plane;
   ra3d_vox_mc_plane(g, -1, kp[1], up[1]);

   for (cz = -1; cz < Z; cz++)
   {
      /* corner dz = 0 is layer cz (the previous pass's dz = 1), dz = 1 is
       * layer cz + 1 */
      { uint8_t *tk = kp[0]; uint32_t *tu = up[0];
        kp[0] = kp[1]; up[0] = up[1]; kp[1] = tk; up[1] = tu; }
      ra3d_vox_mc_plane(g, cz + 1, kp[1], up[1]);
      /* z-uniform grid: the cells of layers 0..Z-2 are one cell translated
       * along z, and every triangle of such a cell spans both of its layers
       * (its mask is the same at z and z+1), so the stack is ONE cell whose
       * far layer is Z-1 — the same surface with Z-1 times fewer triangles.
       * Layer 1's plane equals layer Z-1's, so the plane rotation still
       * holds when the loop jumps to the back cells. */
      stretch = (g->zext && cz == 0 && Z >= 3) ? Z - 1 : 1;
      for (cy = -1; cy < H; cy++)          /* y UP, as Tile3D indexes it */
         for (cx = -1; cx < W; cx++)
         {
            uint32_t uv[8];
            int key[8], cols[8], ncol = 0, l, ci, same = 1;
            int pos[8][3];                   /* region px, y DOWN, layer */
            for (l = 0; l < 8; l++)
            {
               size_t i;
               int dz = ra3d_mc_corner[l][2];
               pos[l][0] = cx + ra3d_mc_corner[l][0];
               pos[l][1] = (H - 1) - (cy + ra3d_mc_corner[l][1]);
               pos[l][2] = cz + dz * stretch;
               i = (size_t)(pos[l][1] + 1) * W2 + (size_t)(pos[l][0] + 1);
               key[l] = kp[dz][i];
               uv[l]  = up[dz][i];
               same &= key[l] == key[0];
            }
            /* all one colour (mask 255, skipped by 3dSen) or all empty */
            if (same) continue;
            for (l = 0; l < 8; l++)
            {
               int k2, seen = 0;
               if (!key[l]) continue;
               for (k2 = 0; k2 < ncol; k2++) if (cols[k2] == key[l]) seen = 1;
               if (!seen) cols[ncol++] = key[l];
            }
            for (ci = 0; ci < ncol; ci++)
            {
               unsigned mask = 0;
               uint32_t tuv = 0;
               const char *t;
               float u0, v0;
               uint16_t r0, r1;
               for (l = 0; l < 8; l++)
                  if (key[l] == cols[ci]) { mask |= 1u << l; tuv = uv[l]; }
               if (mask == 255u) continue;
               r0 = (uint16_t)(tuv & 0xFFFF); r1 = (uint16_t)(tuv >> 16);
               u0 = (float)r0 + 0.5f;          /* slot.Coord2Uv(val + 0.5) */
               v0 = (float)r1 + 0.5f;
               for (t = ra3d_mc_tri[mask]; t[0] && t[1] && t[2]; t += 3)
               {
                  float p[3][3], ref[3] = { 0.0f, 0.0f, 0.0f }, e1[3], e2[3], n[3];
                  float len, dot;
                  int vi, a, cc, pk[3];
                  uint32_t packed;
                  int buried = 1;
                  for (vi = 0; vi < 3; vi++)
                  {
                     int e = (t[vi] <= '9') ? t[vi] - '0' : t[vi] - 'a' + 10;
                     int ca = ra3d_mc_edge[e][0], cb = ra3d_mc_edge[e][1];
                     int in_c  = ((mask >> ca) & 1u) ? ca : cb;
                     int out_c = ((mask >> ca) & 1u) ? cb : ca;
                     buried &= key[out_c] != 0;
                     /* voxel-unit frame: x right, y down, z toward the viewer */
                     p[vi][0] = (float)pos[out_c][0];
                     p[vi][1] = (float)pos[out_c][1];
                     p[vi][2] = (float)-pos[out_c][2];
                     ref[0] += (float)(pos[out_c][0] - pos[in_c][0]);
                     ref[1] += (float)(pos[out_c][1] - pos[in_c][1]);
                     ref[2] -= (float)(pos[out_c][2] - pos[in_c][2]);
                  }
                  /* deviation 4: every vertex on ANOTHER colour's
                   * voxel — a colour border inside the solid, which 3dSen
                   * meshes through the whole depth. The visible hull's
                   * vertices all sit on empty corners and it encloses every
                   * solid corner, so this triangle is buried: skip it (the
                   * title sign alone is 3x lighter) */
                  if (buried) continue;
                  for (a = 0; a < 3; a++) { e1[a] = p[1][a] - p[0][a]; e2[a] = p[2][a] - p[0][a]; }
                  n[0] = e1[1] * e2[2] - e1[2] * e2[1];
                  n[1] = e1[2] * e2[0] - e1[0] * e2[2];
                  n[2] = e1[0] * e2[1] - e1[1] * e2[0];
                  /* two crossed edges can share an outside corner: the
                   * triangle is then a line (no area, nothing drawn) */
                  if (n[0] == 0.0f && n[1] == 0.0f && n[2] == 0.0f) continue;
                  /* outward = from the inside corners to the outside ones;
                   * the winding flips with it so it stays consistent */
                  dot = n[0] * ref[0] + n[1] * ref[1] + n[2] * ref[2];
                  if (dot < 0.0f)
                  {
                     float tmp;
                     for (a = 0; a < 3; a++)
                     { n[a] = -n[a]; tmp = p[1][a]; p[1][a] = p[2][a]; p[2][a] = tmp; }
                  }
                  /* into the unit-box frame the instance's normal matrix
                   * takes (u = scaled voxel position / box size) */
                  n[0] *= fx; n[1] *= fy; n[2] *= (float)(Z + 1);
                  len = sqrtf(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
                  for (a = 0; a < 3; a++) n[a] /= len;
                  {
                     float ax = fabsf(n[0]), ay = fabsf(n[1]), az = fabsf(n[2]);
                     int ni = (ax >= ay && ax >= az) ? (n[0] > 0 ? 0 : 1)
                            : (ay >= az)             ? (n[1] > 0 ? 2 : 3)
                            :                          (n[2] > 0 ? 4 : 5);
                     for (a = 0; a < 3; a++) pk[a] = (int)(uint8_t)ra3d_vox_snorm8(n[a]);
                     packed = (uint32_t)ni | 8u | ((uint32_t)pk[0] << 8)
                            | ((uint32_t)pk[1] << 16) | ((uint32_t)pk[2] << 24);
                  }
                  if (!ra3d_vox_grow((void **)&c->verts, &c->cap_verts,
                                     c->nverts + 3, sizeof(Ra3dVoxVert)))
                     return 0;
                  for (cc = 0; cc < 3; cc++)
                  {
                     Ra3dVoxVert *vv = &c->verts[c->nverts++];
                     /* voxel centre (x + 0.5), scaled n/(n+1) about Pos;
                      * z normalised by Z, centred, toward the viewer */
                     vv->x = px0 + (p[cc][0] + 0.5f - px0) * sx;
                     vv->y = py0 + (p[cc][1] + 0.5f - py0) * sy;
                     vv->z = (p[cc][2] - 0.5f + hz) / (float)(Z + 1);
                     vv->packed = packed;
                     vv->u = u0; vv->v = v0;
                     vv->rect[0] = r0;                  vv->rect[1] = r1;
                     vv->rect[2] = (uint16_t)(r0 + 1u); vv->rect[3] = (uint16_t)(r1 + 1u);
                  }
               }
            }
         }
      if (stretch > 1) cz = Z - 2;   /* next: the back cells, layer Z-1 */
   }
   return 1;
}

/* ------------------------------------------------------------- the build */

static int ra3d_vox_u64_cmp(const void *a, const void *b)
{
   uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
   return (x > y) - (x < y);
}

static double ra3d_vox_now(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec * 1000.0 + ts.tv_nsec / 1.0e6;
}

/* Inserts a mesh entry for key k, meshing via the grid. Returns entry + 1. */
static uint32_t ra3d_vox_insert(Ra3dVoxCache *c, const uint8_t *k, uint32_t kn,
                                uint64_t h, Ra3dVoxGrid *g, int region)
{
   Ra3dVoxEntry en;
   uint32_t slot, t;
#ifdef RA3D_VOX_DEBUG
   double tdbg = ra3d_vox_now();
#endif
   if (c->nents + 1 > (c->table_mask + 1) / 2) return 0;
   if (!ra3d_vox_grow((void **)&c->ents, &c->cap_ents, c->nents + 1, sizeof(Ra3dVoxEntry)) ||
       !ra3d_vox_grow((void **)&c->keys, &c->cap_keys, c->nkeys + kn, 1))
      return 0;
   memset(&en, 0, sizeof(en));
   en.hash = h; en.key_off = c->nkeys; en.key_len = kn;
   en.first = c->nverts;
   if (!region)
   {
      if (!ra3d_vox_mesh_tile(c, g, 0, 0.0f, 0.0f)) return 0;
   }
   else if (g->marching)
   {
      if (!ra3d_vox_mesh_marching(c, g)) return 0;
   }
   else
   {
      for (t = 0; t < (uint32_t)(g->gw * g->gh); t++)
         if (g->present[t])
            if (!ra3d_vox_mesh_tile(c, g, (int)t, (float)((t % g->gw) * 8),
                                    (float)((t / g->gw) * 8)))
               return 0;
   }
   en.count = c->nverts - en.first;
#ifdef RA3D_VOX_DEBUG
   fprintf(stderr, "vox miss: %s %dx%d Z=%d -> %u verts, mesh %.3f ms\n",
           region ? "region" : "tile", g->W, g->H, g->Z, en.count, ra3d_vox_now() - tdbg);
#endif
   memcpy(c->keys + c->nkeys, k, kn);
   c->nkeys += kn;
   c->ents[c->nents++] = en;
   slot = (uint32_t)h & c->table_mask;
   while (c->table[slot]) slot = (slot + 1) & c->table_mask;
   c->table[slot] = c->nents;
   return c->nents;
}

static int ra3d_vox_piece(Ra3dVoxCache *c, uint32_t *np, uint32_t ent,
                          uint32_t inst, uint32_t cell, float ox, float oy,
                          uint32_t blend)
{
   if (!ent) return 1;
   c->ents[ent - 1].stamp = c->stamp;   /* drawn by this build */
   if (!c->ents[ent - 1].count) return 1;
   if (!ra3d_vox_grow((void **)&c->pieces, &c->cap_pieces, *np + 1, sizeof(Ra3dVoxPiece)) ||
       !ra3d_vox_grow((void **)&c->pkey, &c->cap_pkey, *np + 1, sizeof(uint64_t)))
      return 0;
   c->pieces[*np].inst = inst; c->pieces[*np].cell = cell;
   c->pieces[*np].ox = ox;     c->pieces[*np].oy = oy;
   /* sort key: blended after opaque, then by mesh entry, then piece order */
   c->pkey[*np] = ((uint64_t)(((blend ? 1u : 0u) << 31) | (ent - 1)) << 32) | *np;
   (*np)++;
   return 1;
}

/* fetch atlas pixel (chr, x, y) with flips applied */
static int ra3d_vox_chr_px(const uint8_t *atlas, unsigned atlas_count,
                           uint32_t chr, uint32_t flip, int x, int y)
{
   if (chr >= atlas_count) return 0;
   if (flip & 1u) x = 7 - x;
   if (flip & 2u) y = 7 - y;
   /* 3 bits — a profile texture's pixel carries 3dSen's extra
    * bit (4-7), so emptyColor 4 can be empty while colour 0 stays solid; the
    * frame's CHR is 0-3 either way. The shader takes `& 3` for the colour. */
   return atlas[((size_t)chr * 8 + (size_t)y) * 8 + (size_t)x] & 7;
}

int ra3d_vox_build(Ra3dVoxCache *c, const Ra3dGeoFrame *g,
                   const uint32_t *slot_of, const uint8_t *atlas,
                   unsigned atlas_count, Ra3dVoxFrame *out)
{
   double t0 = ra3d_vox_now(), tm = 0.0;
   uint32_t np = 0, i, r;

   memset(out, 0, sizeof(*out));
   if (!c || !g || !atlas) return 0;

   if (c->flush_verts < RA3D_VOX_FLUSH_VERTS) c->flush_verts = RA3D_VOX_FLUSH_VERTS;
   if (c->nverts > c->flush_verts || c->nents > RA3D_VOX_FLUSH_ENTS)
      ra3d_vox_compact(c);   /* was ra3d_vox_flush */
   c->stamp++;
   if (!c->stamp) c->stamp = 1;

   /* per-frame memo: atlas indices are only meaningful within a frame */
   if (!ra3d_vox_grow((void **)&c->memo, &c->cap_memo, atlas_count * 4 + 1, sizeof(uint32_t)))
      return 0;
   memset(c->memo, 0, (size_t)(atlas_count * 4 + 1) * sizeof(uint32_t));

   for (i = 0; i < g->instance_count; i++)
   {
      const Ra3dGeoInstance *in = &g->instances[i];
      uint32_t gw = (uint32_t)(in->size[0] / 8.0f + 0.5f);
      uint32_t gh = (uint32_t)(in->size[1] / 8.0f + 0.5f);
      uint32_t slot = slot_of[i];
      uint32_t blend = in->alpha < 0.999f;
      int empty = (int)((in->flags >> RA3D_INST_EMPTY_SHIFT) & 7u);
      int warp  = (in->flags & RA3D_INST_FULLWARP) != 0;
      int march = (in->flags & RA3D_INST_MARCHING) != 0;
      int share = (in->flags & RA3D_INST_TILESHARE) != 0;
      uint32_t a;
      if (!gw) gw = 1;
      if (!gh) gh = 1;
      if (in->flags & RA3D_INST_HIDDEN)
         continue;   /* neither drawn nor cast — Lua keeps every variant */
      if ((size_t)gw * gh != in->cell_count ||
          in->cell_offset + in->cell_count > g->cell_count)
         continue;   /* never index past the cell array */

      if (march) out->marching++;
      if (in->geo == 0 && !warp && !march)
      {
         /* plain Default: per tile, unit depth */
         for (a = 0; a < in->cell_count; a++)
         {
            const Ra3dGeoCell *cl = &g->cells[in->cell_offset + a];
            uint32_t ent = 0, memo_ix;
            if (cl->chr == RA3D_CELL_EMPTY || cl->chr >= atlas_count) continue;
            memo_ix = (uint32_t)cl->chr * 4u + (cl->flip & 3u);
            if (empty == 0 && c->memo[memo_ix]) ent = c->memo[memo_ix];
            else
            {
               uint8_t k[66];   /* one byte per 3-bit pixel */
               int x, y;
               uint64_t h;
               memset(k, 0, sizeof(k));
               for (y = 0; y < 8; y++)
                  for (x = 0; x < 8; x++)
                     k[y * 8 + x] = (uint8_t)ra3d_vox_chr_px(atlas, atlas_count, cl->chr, cl->flip, x, y);
               k[64] = 'T'; k[65] = (uint8_t)empty;
               h = ra3d_vox_hash(k, 66);
               ent = ra3d_vox_find(c, k, 66, h);
               if (ent) out->hits++;
               else
               {
                  double tt = ra3d_vox_now();
                  Ra3dVoxGrid vg;
                  uint8_t img[64], pres = 1, touched = 0, occ[3 * RA3D_VOX_MAXZ];
                  for (y = 0; y < 8; y++)
                     for (x = 0; x < 8; x++)
                        img[y * 8 + x] = (uint8_t)ra3d_vox_chr_px(atlas, atlas_count,
                                                                  cl->chr, cl->flip, x, y);
                  if (c->cap_vox < 8 * 8 * 3)
                  {
                     uint32_t *nv = (uint32_t *)realloc(c->vox, 8 * 8 * 3 * sizeof(uint32_t));
                     if (!nv) return 0;
                     c->vox = nv; c->cap_vox = 8 * 8 * 3;
                  }
                  memset(&vg, 0, sizeof(vg));
                  vg.vox = c->vox; vg.img = img; vg.present = &pres;
                  vg.W = 8; vg.H = 8; vg.gw = 1; vg.gh = 1; vg.Z = 1; vg.empty = empty;
                  vg.touched = &touched; vg.occ = occ;
                  ra3d_vox_default(&vg);
                  ent = ra3d_vox_insert(c, k, 66, h, &vg, 0);
                  out->meshed++;
                  tm += ra3d_vox_now() - tt;
                  if (!ent) { ra3d_vox_flush(c); return 0; }
               }
               if (empty == 0) c->memo[memo_ix] = ent;
            }
            if (!ra3d_vox_piece(c, &np, ent, slot, in->cell_offset + a,
                                (float)(cl->gx * 8), (float)(cl->gy * 8), blend))
               return 0;
         }
      }
      else
      {
         /* pattern-level fill: the whole region is one entry */
         uint32_t W = gw * 8, H = gh * 8, kn, t;
         int Z = (int)lroundf(in->size[2]);
         uint64_t h;
         uint32_t ent;
         if (Z < 1) Z = 1;
         if (Z > (int)RA3D_VOX_MAXZ) Z = (int)RA3D_VOX_MAXZ;
         if (W * H > 256u * 256u) continue;
         if (!ra3d_vox_grow((void **)&c->img, &c->cap_img, W * H, 1) ||
             !ra3d_vox_grow((void **)&c->present, &c->cap_present, gw * gh, 1))
            return 0;
         memset(c->img, 0, W * H);
         for (t = 0; t < gw * gh; t++)
         {
            const Ra3dGeoCell *cl = &g->cells[in->cell_offset + t];
            int x, y;
            c->present[t] = (cl->chr != RA3D_CELL_EMPTY && cl->chr < atlas_count);
            if (!c->present[t]) continue;
            for (y = 0; y < 8; y++)
               for (x = 0; x < 8; x++)
                  c->img[((t / gw) * 8 + (uint32_t)y) * W + (t % gw) * 8 + (uint32_t)x] =
                     (uint8_t)ra3d_vox_chr_px(atlas, atlas_count, cl->chr, cl->flip, x, y);
         }
         /* 3dSen keys its Tile3Ds by Tile2D (the raw CHR + flipX + flipY;
          * no palette), so cells of one identity
          * share one voxel block. Identity here = the atlas tile's unflipped
          * pixels + the flip bits (two atlas slots holding the same CHR still
          * count as one) + the cell's palette group and texture tile. The
          * last two are a deliberate split: our fragment takes the palette
          * from the cell under the stored uv, where 3dSen takes it from the
          * drawn tile, so sharing a block across palettes would recolour it
          * (Ice Hockey's flag). Same-CHR cells in different palettes keep
          * separate blocks — exact wherever a CHR keeps one palette in its
          * region (SMB's hill, bushes and ground). */
         if (share)
         {
            uint32_t n = gw * gh, tsz = 16;
            while (tsz < n * 2) tsz *= 2;
            if (!ra3d_vox_grow((void **)&c->alias, &c->cap_alias, n, sizeof(uint32_t)) ||
                !ra3d_vox_grow((void **)&c->ihash, &c->cap_ihash, n, sizeof(uint64_t)) ||
                !ra3d_vox_grow((void **)&c->itab, &c->cap_itab, tsz, sizeof(uint32_t)))
               return 0;
            memset(c->itab, 0, (size_t)tsz * sizeof(uint32_t));
            for (t = 0; t < n; t++)
            {
               const Ra3dGeoCell *cl = &g->cells[in->cell_offset + t];
               uint32_t s;
               c->alias[t] = t;
               if (!c->present[t]) continue;
               {
                  const uint8_t *px = &atlas[(size_t)cl->chr * 64];
                  uint8_t ik[69];
                  memcpy(ik, px, 64); ik[64] = (uint8_t)(cl->flip & 3u);
                  ik[65] = cl->pal; ik[66] = (uint8_t)cl->pad; ik[67] = (uint8_t)(cl->pad >> 8);
                  ik[68] = 0;
                  c->ihash[t] = ra3d_vox_hash(ik, 69);
               }
               for (s = (uint32_t)c->ihash[t] & (tsz - 1); c->itab[s]; s = (s + 1) & (tsz - 1))
               {
                  uint32_t o = c->itab[s] - 1;
                  const Ra3dGeoCell *co = &g->cells[in->cell_offset + o];
                  if (c->ihash[o] == c->ihash[t] && (co->flip & 3u) == (cl->flip & 3u) &&
                      co->pal == cl->pal && co->pad == cl->pad &&
                      (co->chr == cl->chr ||
                       !memcmp(&atlas[(size_t)co->chr * 64], &atlas[(size_t)cl->chr * 64], 64)))
                  { c->alias[t] = o; break; }
               }
               if (!c->itab[s]) c->itab[s] = t + 1;
            }
         }
         /* key: header + presence + pixels (one byte each; regions are few)
          * + alias map (two bytes a tile) when tiles share */
         kn = 12 + gw * gh + W * H + (share ? 2 * gw * gh : 0);
         if (!ra3d_vox_grow((void **)&c->key, &c->cap_key, kn, 1)) return 0;
         c->key[0] = 'R'; c->key[1] = in->geo; c->key[2] = (uint8_t)Z;
         c->key[3] = (uint8_t)(in->flags >> 2);
         c->key[4] = (uint8_t)((in->flags >> 8) & 7u);   /* emptyColor only; shadow bits are not mesh inputs */
         c->key[5] = (uint8_t)gw; c->key[6] = (uint8_t)(gw >> 8);
         c->key[7] = (uint8_t)gh; c->key[8] = (uint8_t)(gh >> 8);
         c->key[9] = (uint8_t)march;   /* same pixels, other mesher */
         c->key[10] = (uint8_t)share;
         c->key[11] = 0;
         memcpy(c->key + 12, c->present, gw * gh);
         memcpy(c->key + 12 + gw * gh, c->img, W * H);
         if (share)
            for (t = 0; t < gw * gh; t++)
            {
               c->key[12 + gw * gh + W * H + 2 * t]     = (uint8_t)c->alias[t];
               c->key[12 + gw * gh + W * H + 2 * t + 1] = (uint8_t)(c->alias[t] >> 8);
            }
         h = ra3d_vox_hash(c->key, kn);
         ent = ra3d_vox_find(c, c->key, kn, h);
         if (ent) out->hits++;
         else if (tm > RA3D_VOX_BUDGET_MS)
         {
            out->deferred++;
            continue;
         }
         else
         {
            double tt = ra3d_vox_now();
            Ra3dVoxGrid vg;
            size_t nvox = (size_t)gw * gh * 64 * (size_t)Z * 3;
            if (nvox > c->cap_vox)
            {
               uint32_t *nv = (uint32_t *)realloc(c->vox, nvox * sizeof(uint32_t));
               if (!nv) return 0;
               c->vox = nv; c->cap_vox = nvox;
            }
            if (!ra3d_vox_grow((void **)&c->touched, &c->cap_touched, gw * gh, 1))
               return 0;
            if ((size_t)gw * gh * 3 * RA3D_VOX_MAXZ > c->cap_occ)
            {
               size_t no = (size_t)gw * gh * 3 * RA3D_VOX_MAXZ;
               uint8_t *np2 = (uint8_t *)realloc(c->occ, no);
               if (!np2) return 0;
               c->occ = np2; c->cap_occ = no;
            }
            memset(c->touched, 0, gw * gh);
            memset(&vg, 0, sizeof(vg));
            vg.touched = c->touched; vg.occ = c->occ;
            vg.vox = c->vox; vg.img = c->img; vg.present = c->present;
            vg.W = (int)W; vg.H = (int)H; vg.gw = (int)gw; vg.gh = (int)gh; vg.Z = Z;
            vg.empty = empty;
            vg.solid      = (in->flags & RA3D_INST_SOLID) != 0;
            vg.fullWarp   = warp;
            vg.antiShadow = (in->flags & RA3D_INST_ANTISHADOW) != 0;
            vg.marching   = march;
            vg.zext       = march && in->geo == 0 && !warp;
            vg.alias      = share ? c->alias : NULL;
#ifdef RA3D_VOX_DEBUG
            double tf0 = ra3d_vox_now();
#endif
            switch (in->geo)
            {
               case 3: ra3d_vox_cube(&vg); break;                               /* CUBE */
               case 1: ra3d_vox_cylinder(&vg, 1, 0, 0); break;                  /* HCYLINDER */
               case 2: ra3d_vox_cylinder(&vg, 0, 0, 0); break;                  /* VCYLINDER */
               case 4: ra3d_vox_cylinder(&vg, 1, 1, (in->flags & RA3D_INST_FLIP) != 0); break;
               case 5: ra3d_vox_cylinder(&vg, 0, 1, (in->flags & RA3D_INST_FLIP) != 0); break;
               default: ra3d_vox_default(&vg); break;                           /* fullWarp */
            }
#ifdef RA3D_VOX_DEBUG
            fprintf(stderr, "vox region fill %.3f ms (alloc+clear %.3f ms)\n",
                    ra3d_vox_now() - tf0, tf0 - tt);
#endif
            ent = ra3d_vox_insert(c, c->key, kn, h, &vg, 1);
            out->meshed++;
            tm += ra3d_vox_now() - tt;
            if (!ent) { ra3d_vox_flush(c); return 0; }
         }
         if (!ra3d_vox_piece(c, &np, ent, slot, in->cell_offset, 0.0f, 0.0f, blend))
            return 0;
      }
   }

   /* sort pieces by (blend, mesh); np is at most a couple of thousand */
   if (!ra3d_vox_grow((void **)&c->sorted, &c->cap_sorted, np + 1, sizeof(Ra3dVoxPiece)) ||
       !ra3d_vox_grow((void **)&c->runs, &c->cap_runs, np + 1, sizeof(Ra3dVoxRun)))
      return 0;
   qsort(c->pkey, np, sizeof(uint64_t), ra3d_vox_u64_cmp);
   r = 0;
   for (i = 0; i < np; i++)
   {
      uint32_t key = (uint32_t)(c->pkey[i] >> 32);
      c->sorted[i] = c->pieces[(uint32_t)c->pkey[i]];
      if (i == 0 || key != (uint32_t)(c->pkey[i - 1] >> 32))
      {
         const Ra3dVoxEntry *en = &c->ents[key & 0x7FFFFFFFu];
         c->runs[r].first = en->first; c->runs[r].count = en->count;
         c->runs[r].piece_first = i; c->runs[r].piece_count = 0;
         c->runs[r].blend = key >> 31;
         if (!(key >> 31)) out->opaque_runs = r + 1;
         r++;
      }
      c->runs[r - 1].piece_count++;
      out->frame_verts += c->runs[r - 1].count;
   }

   out->pieces = c->sorted; out->piece_count = np;
   out->runs = c->runs;     out->run_count = r;
   out->entries = c->nents;
   out->compactions = c->compactions;
   out->mesh_ms = tm;
   {  /* this frame's distinct meshes must fit with room to spare */
      uint64_t used = 0;
      for (i = 0; i < r; i++) used += c->runs[i].count;
      if (used * 2 > c->flush_verts)
         c->flush_verts = used * 2 > RA3D_VOX_FLUSH_MAX ? RA3D_VOX_FLUSH_MAX : (uint32_t)(used * 2);
   }
   out->total_ms = ra3d_vox_now() - t0;
   return 1;
}

#endif /* RA3D_VOX_IMPLEMENTATION */
#endif /* RA3D_VOX_H */
