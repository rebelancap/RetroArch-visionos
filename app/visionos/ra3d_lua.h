/* ra3d_lua.h — 3dSen profile Lua, run the way 3dSenVR runs it (..).
 *
 *   #define RA3D_SHAPE_IMPLEMENTATION
 *   #include "ra3d_shape.h"
 *   ...
 *   #define RA3D_LUA_IMPLEMENTATION
 *   #include "ra3d_lua.h"          <- LAST in the translation unit
 *
 * Header-only for the same reason as ra3d_shape.h: a new .c/.m would
 * have to edit inside overlay 0013's pbxproj hunk. The implementation block
 * compiles RetroArch's own vendored Lua 5.3.6 (vendor/RetroArch/deps/lua, MIT,
 * untouched — it is #included by relative path, nothing under vendor/ is
 * edited) as a unity build at the very end, after the binding, so Lua's
 * internal macros (G, cast, ...) never see a line of ours. Only base, math,
 * table and string are opened; loslib/liolib/loadlib/lcorolib/ldblib/linit
 * are not even compiled. `dofile/loadfile/load/require/collectgarbage` are
 * removed, and every call into a script runs under an instruction budget.
 *
 * WHAT IT REPRODUCES (3dSen's script semantics, as profiles rely on them):
 *   - ONE lua_State for every script of the profile; each script's source is
 *     run at load in FILE order (= 3dSen's sorted order) after the ten entry
 *     names are nil'd, and its Start/Update/UpdateS/LateUpdate/End/... are
 *     captured right after — so helper functions and globals are shared;
 *   - Start for every script at load (Start runs even for a disabled script,
 *     as 3dSen does), End at unload;
 *   - per emulated frame: frame/time, every Update, then every UpdateS once
 *     per LINKED shape with globals `shape`/`shape2D` set (a tag in common or
 *     `*` in the script's TagStr), then every LateUpdate;
 *   - per-frame copies: each matched Pattern3D starts the frame with its
 *     authored Offset/Rot/Scale/Pivot/renderStyle/layer/alpha; writes to
 *     Setting / Light / Backdrop / Camera / globals persist;
 *   - any error (including the budget, and an unknown member — 3dSen raises on
 *     those too) disables that script for the rest of the session, logged once.
 *
 * Pure C99 + Lua's public API. No Foundation, no Metal. The renderer-facing
 * results are the instance array (written back in place, plus inserted shapes
 * and the Backdrop box appended) and Ra3dLuaState.
 */
#ifndef RA3D_LUA_H
#define RA3D_LUA_H

#include "ra3d_shape.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Ra3dLua Ra3dLua;

/* What the scripts left in 3dSen's globals, for the renderer. */
typedef struct
{
   int      empty_tile;          /* Setting.EmptyTile                       */
   int      localcam;            /* Setting.LocalCam / TopDownCam           */
   float    clip[4];             /* Setting.Clipping, 3dSen order           */
   uint8_t  layer_cast[6], layer_recv[6];   /* Setting.Layer[n]             */
   int      light_col_set, light_dir_set;
   float    light_col[3];        /* sRGB, Light.Color                       */
   float    light_dir[3];        /* 3dSen frame, Light.Direction            */
   int      bd_enable, bd_recv;  /* Backdrop                                */
   float    bd_color[4], bd_size[3], bd_ofs[3];
   int      cam_set;             /* the scripts wrote Camera at least once  */
   float    cam_rot[3], cam_dist;
   uint32_t cam_gen;             /* bumps on every CHANGE of rot/distance   */
   /* ZapperOffset (3dSen frame px: +Y up, +Z away from the
    * viewer). The light-gun profiles move their targets in 3D and leave here
    * how far, so the gun can aim at what is drawn (as 3dSen's Zapper: the plane
    * the ray is cast against moves by z, the hit then drops x/y). Kept across
    * frames, as 3dSen's is; zero until a script writes it. */
   float    zapper_ofs[3];
   uint8_t  pal_idx[64];         /* this frame's 16 palettes, NES indices   */
   /* CHR the frame needs beyond the scene's own atlas: inserted shapes'
    * authored tiles, then the Backdrop's solid tile. Index i is atlas entry
    * scene->AtlasCount + i. 16 raw bytes each. */
   uint8_t *xatlas;
   uint32_t xatlas_n, xatlas_cap;
   /* stats */
   double   ms, ms_peak;         /* last frame / peak since reset           */
   uint32_t scripts, alive, inserted, scriptable, calls;
} Ra3dLuaState;

typedef void (*ra3d_lua_log_fn)(const char *line);

/* Builds the VM for `prof` and runs every script's chunk and Start. NULL if
 * the profile has no scripts or the VM cannot be made. `budget` is the
 * instruction budget per call (0 = default 5,000,000). */
Ra3dLua *ra3d_lua_new(const Ra3dProfile *prof, ra3d_lua_log_fn logfn, long budget);
/* Runs End, closes the VM. */
void     ra3d_lua_free(Ra3dLua *rt);
/* Fills the per-frame palette table from `scene` (Converter: entry i = palette
 * RAM i % 32, colour 0 of every group = the backdrop), runs Update / UpdateS /
 * LateUpdate against the instances ra3d_build_frame put in `g`, then writes
 * the scripts' per-instance results back into `g` and appends inserted shapes
 * and the Backdrop box. `ram` is the 2 KB NES RAM (may be NULL). */
int      ra3d_lua_frame(Ra3dLua *rt, const Ra3dScene *scene, const uint8_t *ram,
                        const Ra3dKnobs *k, Ra3dGeoFrame *g);
const Ra3dLuaState *ra3d_lua_state(const Ra3dLua *rt);
void     ra3d_lua_reset_peak(Ra3dLua *rt);
/* Harness: run a chunk in the profile's globals (budgeted); 0 on error. */
int      ra3d_lua_eval(Ra3dLua *rt, const char *code);

#ifdef __cplusplus
}
#endif
#endif /* RA3D_LUA_H */

/* ========================================================================== */
/* Outside the include guard on purpose: a file may include the declarations
 * early and define RA3D_LUA_IMPLEMENTATION + include again at its very end. */
#if defined(RA3D_LUA_IMPLEMENTATION) && !defined(RA3D_LUA_IMPLEMENTED)
#define RA3D_LUA_IMPLEMENTED

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <math.h>
#include "../../vendor/RetroArch/deps/lua/src/lua.h"
#include "../../vendor/RetroArch/deps/lua/src/lauxlib.h"
#include "../../vendor/RetroArch/deps/lua/src/lualib.h"

#define RA_LUA_NFN 10
enum { RA_FN_START, RA_FN_UPDATE, RA_FN_UPDATES, RA_FN_END, RA_FN_LATE,
       RA_FN_DETECT, RA_FN_BUILD, RA_FN_LOAD, RA_FN_SAVE, RA_FN_INPUT };
static const char *const RA_LUA_FNAMES[RA_LUA_NFN] = {
   "Start", "Update", "UpdateS", "End", "LateUpdate",
   "DetectShape", "BuildPattern", "Load", "Save", "InputProcess" };

typedef struct
{
   const char *name, *tags;
   uint32_t    tag_len;
   int         fn[RA_LUA_NFN];   /* registry refs, LUA_NOREF if absent */
   uint8_t     enabled, err, star;
   uint32_t    list_first, list_n;   /* this frame's linked shapes */
} RaLuaScript;

/* One Pattern3D of this frame, as the scripts see it (3dSen's per-frame copy).
 * Offset/Rot/Scale/Pivot are in 3dSen's 3dSen frame, exactly as authored. */
typedef struct
{
   float    off[3], rot[3], scl[3], piv[3];
   float    alpha;
   int32_t  style;          /* renderStyle: 0 hidden, 1 normal, 2 shadow only */
   int32_t  custom_pal;     /* -1 = the region's own                          */
   uint8_t  layer, cast, recv, scriptable;
   uint32_t inst;           /* index in g->instances, or pending insert       */
   uint32_t shape;          /* profile Pattern3D                              */
   uint32_t region;         /* index in rt->rg                                */
   int32_t  ins_pal;        /* inserted: AddNewShape's pal, else -1           */
} RaLuaInst;

struct Ra3dLua
{
   lua_State          *L;
   const Ra3dProfile  *prof;
   Ra3dLuaState        st;
   ra3d_lua_log_fn     logfn;
   int                 logs;
   long                budget, left;

   RaLuaScript        *sc;
   uint32_t            ns;
   uint64_t           *links;     /* per profile shape, ceil(ns/64) words */
   uint32_t            lwords;

   /* per frame */
   uint32_t            gen;
   RaLuaInst          *li;   uint32_t nli, cap_li;
   Ra3dGeoRegion      *rg;   uint32_t nrg, cap_rg;
   uint32_t           *scr;  uint32_t nscr, cap_scr;     /* scriptable li, frame order */
   uint32_t           *lists; uint32_t cap_lists;
   const Ra3dScene    *scene;
   const uint8_t      *ram;
   const Ra3dKnobs    *k;
   Ra3dGeoFrame       *g;
   int                 cache_ref;  /* registry: li -> Shape userdata, this frame */
   int32_t            *var_x; uint32_t cap_var_x; uint32_t var_gen, *var_g;
   int                 dead_err;
};

static RaLuaInst RA_LUA_DEAD;   /* stale-reference sink: zeros, disabled */

static Ra3dLua *ra_lua_rt(lua_State *L) { return *(Ra3dLua **)lua_getextraspace(L); }

static void ra_lua_logf(Ra3dLua *rt, const char *fmt, ...)
{
   char buf[512];
   va_list ap;
   if (!rt->logfn || rt->logs >= 96) return;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   rt->logs++;
   rt->logfn(buf);
}

static int ra_lua_grow(void **v, uint32_t *cap, uint32_t need, size_t esz)
{
   uint32_t c;
   void *np;
   if (need <= *cap) return 1;
   c = *cap ? *cap : 64;
   while (c < need) c *= 2;
   np = realloc(*v, (size_t)c * esz);
   if (!np) return 0;
   *v = np; *cap = c;
   return 1;
}

/* ---------------------------------------------------------------- tags */

/* Does the comma-separated tag string (s, n) contain `tag` (trimmed, exact)?
 * Pattern3D.ContainsTag: "*" matches everything. */
static int ra_lua_tags_has(const char *s, size_t n, const char *tag, size_t tn)
{
   size_t i = 0;
   if (tn == 1 && tag[0] == '*') return 1;
   while (i <= n)
   {
      size_t a = i, b;
      while (i < n && s[i] != ',') i++;
      b = i;
      while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n')) a++;
      while (b > a && (s[b-1] == ' ' || s[b-1] == '\t' || s[b-1] == '\r' || s[b-1] == '\n')) b--;
      if (b - a == tn && tn && !memcmp(s + a, tag, tn)) return 1;
      i++;
   }
   return 0;
}

static int ra_lua_shape_has_tag(const Ra3dProfile *p, uint32_t shape, const char *tag, size_t tn)
{
   const Ra3dShape3D *sh;
   if (shape >= p->shapes.n) return 0;
   sh = &p->shapes.v[shape];
   if (tn == 1 && tag[0] == '*') return 1;
   return sh->tag_len && ra_lua_tags_has(p->tagpool.v + sh->tag_off, sh->tag_len, tag, tn);
}

/* ------------------------------------------------------------ userdata */

/* 3dSen's reset distance at FOV 70, Scene Scale 1:
 * 132.7964 / tan(35 deg) (v2) = 104 / atan(35 deg) (v1) = 189.653. */
#define RA3D_LUA_CAM_RESET_DIST 189.653

#define RA_MT_SHAPE  "ra3d.Pattern3D"
#define RA_MT_SHAPE2 "ra3d.Shape"
#define RA_MT_PSHAPE "ra3d.ProfilePattern3D"
#define RA_MT_VEC    "ra3d.Vector3"
#define RA_MT_COL    "ra3d.Color"
#define RA_MT_REF    "ra3d.PVector3"
#define RA_MT_CDATA  "ra3d.CustomData"
#define RA_MT_LIST   "ra3d.List"
#define RA_MT_OBJ    "ra3d.Object"
#define RA_MT_MAT    "ra3d.PMatrix4x4"

typedef struct { uint32_t gen, li; } RaUShape;
typedef struct { uint32_t shape; } RaUPShape;
typedef struct { float v[3]; } RaUVec;
typedef struct { float v[4]; } RaUCol;
enum { RA_REF_OFF, RA_REF_ROT, RA_REF_SCL, RA_REF_PIV, RA_REF_CAMROT,
       RA_REF_BDSIZE, RA_REF_BDOFS, RA_REF_CLIP, RA_REF_DUMMY, RA_REF_ZAPOFS };
typedef struct { uint32_t kind, gen, li; float dummy[4]; } RaURef;
enum { RA_LIST_SHAPE, RA_LIST_PSHAPE };
typedef struct { uint32_t kind, gen, n; uint32_t items[1]; } RaUList;
enum { RA_OBJ_FRAME, RA_OBJ_SETTING, RA_OBJ_LIGHT, RA_OBJ_BACKDROP, RA_OBJ_CAMERA,
       RA_OBJ_SCRIPT, RA_OBJ_PALETTE, RA_OBJ_PATTERN, RA_OBJ_NOTI, RA_OBJ_PROFILE,
       RA_OBJ_SCRIPTPAD, RA_OBJ_VIDEO, RA_OBJ_LAYERS, RA_OBJ_LAYERP, RA_OBJ_PAD,
       RA_OBJ_PADS };
typedef struct { uint32_t kind; int32_t n; } RaUObj;

static RaLuaInst *ra_lua_inst(Ra3dLua *rt, uint32_t gen, uint32_t li)
{
   if (gen != rt->gen || li >= rt->nli) return &RA_LUA_DEAD;
   return &rt->li[li];
}

static void ra_lua_push_vec(lua_State *L, float x, float y, float z)
{
   RaUVec *u = (RaUVec *)lua_newuserdata(L, sizeof(*u));
   u->v[0] = x; u->v[1] = y; u->v[2] = z;
   luaL_setmetatable(L, RA_MT_VEC);
}

static void ra_lua_push_col(lua_State *L, float r, float g, float b, float a)
{
   RaUCol *u = (RaUCol *)lua_newuserdata(L, sizeof(*u));
   u->v[0] = r; u->v[1] = g; u->v[2] = b; u->v[3] = a;
   luaL_setmetatable(L, RA_MT_COL);
}

static void ra_lua_push_ref(lua_State *L, uint32_t kind, uint32_t gen, uint32_t li)
{
   RaURef *u = (RaURef *)lua_newuserdata(L, sizeof(*u));
   memset(u, 0, sizeof(*u));
   u->kind = kind; u->gen = gen; u->li = li;
   luaL_setmetatable(L, RA_MT_REF);
}

static void ra_lua_push_obj(lua_State *L, uint32_t kind, int32_t n)
{
   RaUObj *u = (RaUObj *)lua_newuserdata(L, sizeof(*u));
   u->kind = kind; u->n = n;
   luaL_setmetatable(L, RA_MT_OBJ);
}

static void ra_lua_push_shape(lua_State *L, uint32_t li)
{
   Ra3dLua *rt = ra_lua_rt(L);
   lua_rawgeti(L, LUA_REGISTRYINDEX, rt->cache_ref);
   if (lua_rawgeti(L, -1, (lua_Integer)li + 1) == LUA_TNIL)
   {
      RaUShape *u;
      lua_pop(L, 1);
      u = (RaUShape *)lua_newuserdata(L, sizeof(*u));
      u->gen = rt->gen; u->li = li;
      luaL_setmetatable(L, RA_MT_SHAPE);
      lua_pushvalue(L, -1);
      lua_rawseti(L, -3, (lua_Integer)li + 1);
   }
   lua_remove(L, -2);
}

static void ra_lua_push_pshape(lua_State *L, uint32_t shape)
{
   RaUPShape *u = (RaUPShape *)lua_newuserdata(L, sizeof(*u));
   u->shape = shape;
   luaL_setmetatable(L, RA_MT_PSHAPE);
}

/* a Vector3 (value) or a PVector3 (reference) on the stack -> xyz */
static int ra_lua_tovec(lua_State *L, int idx, float out[3])
{
   RaUVec *v = (RaUVec *)luaL_testudata(L, idx, RA_MT_VEC);
   if (v) { memcpy(out, v->v, sizeof(float) * 3); return 1; }
   if (luaL_testudata(L, idx, RA_MT_REF))
   {
      int i;
      for (i = 0; i < 3; i++)
      {
         lua_pushinteger(L, i);
         lua_gettable(L, idx < 0 ? idx - 1 : idx);
         out[i] = (float)lua_tonumber(L, -1);
         lua_pop(L, 1);
      }
      return 1;
   }
   return 0;
}

static int ra_lua_axis(lua_State *L, int idx)
{
   if (lua_type(L, idx) == LUA_TNUMBER)
   {
      lua_Number n = lua_tonumber(L, idx);
      int a = (int)floor(n);
      return (a >= 0 && a <= 3) ? a : -1;
   }
   if (lua_type(L, idx) == LUA_TSTRING)
   {
      size_t n; const char *s = lua_tolstring(L, idx, &n);
      if (n == 1) switch (s[0]) { case 'x': return 0; case 'y': return 1; case 'z': return 2; case 'w': return 3; }
   }
   return -1;
}

/* ------------------------------------------------- shape geometry (3dSen) */

static const Ra3dGeoRegion *ra_lua_region(Ra3dLua *rt, const RaLuaInst *in)
{
   static const Ra3dGeoRegion zero;
   if (in == &RA_LUA_DEAD || in->region >= rt->nrg) return &zero;
   return &rt->rg[in->region];
}

static float ra_lua_sizez(Ra3dLua *rt, const RaLuaInst *in)
{
   if (in == &RA_LUA_DEAD || in->shape >= rt->prof->shapes.n) return 0.0f;
   return rt->prof->shapes.v[in->shape].size_z;
}

/* Pattern3D GetPos(pivot): lerp(low, high, pivot) + Offset, 3dSen frame,
 * low/high from the shape's start/end and the layer's Offset + Aligned. */
static void ra_lua_getpos(Ra3dLua *rt, const RaLuaInst *in, const float p[3], float out[3])
{
   const Ra3dGeoRegion *r = ra_lua_region(rt, in);
   float sz = ra_lua_sizez(rt, in);
   int rl = (in->layer == 0 || in->layer > 5) ? 2 : in->layer;
   /* the box's NEAR face, 3dSen z, from the same placement the
    * renderer uses (its centre, minus half the depth) */
   float lo = rt->k ? -ra3d_layer_centre_z(rt->prof, rt->k, rl, sz) - 0.5f * sz : 0.0f;
   float lx = (float)r->px0, hx = (float)(r->px1 + 1);
   float ly = (float)(RA3D_UNITY_H - r->py1 - 1), hy = (float)(RA3D_UNITY_H - r->py0);
   out[0] = lx + (hx - lx) * p[0] + in->off[0];
   out[1] = ly + (hy - ly) * p[1] + in->off[1];
   out[2] = lo + sz * p[2] + in->off[2];
}

/* ------------------------------------------------------------- Vector3 */

static int ra_vec_index(lua_State *L)
{
   RaUVec *v = (RaUVec *)luaL_checkudata(L, 1, RA_MT_VEC);
   int a = ra_lua_axis(L, 2);
   const char *k;
   if (a >= 0 && a < 3) { lua_pushnumber(L, v->v[a]); return 1; }
   k = lua_tostring(L, 2);
   if (!k) return luaL_error(L, "Vector3: bad index");
   if (!strcmp(k, "magnitude"))
   { lua_pushnumber(L, sqrt((double)v->v[0]*v->v[0] + (double)v->v[1]*v->v[1] + (double)v->v[2]*v->v[2])); return 1; }
   if (!strcmp(k, "sqrMagnitude"))
   { lua_pushnumber(L, (double)v->v[0]*v->v[0] + (double)v->v[1]*v->v[1] + (double)v->v[2]*v->v[2]); return 1; }
   if (!strcmp(k, "normalized"))
   {
      double m = sqrt((double)v->v[0]*v->v[0] + (double)v->v[1]*v->v[1] + (double)v->v[2]*v->v[2]);
      if (m < 1e-5) ra_lua_push_vec(L, 0, 0, 0);
      else ra_lua_push_vec(L, (float)(v->v[0]/m), (float)(v->v[1]/m), (float)(v->v[2]/m));
      return 1;
   }
   return luaL_error(L, "Vector3: no member '%s'", k);
}

static int ra_vec_newindex(lua_State *L)
{
   RaUVec *v = (RaUVec *)luaL_checkudata(L, 1, RA_MT_VEC);
   int a = ra_lua_axis(L, 2);
   if (a < 0 || a > 2) return luaL_error(L, "Vector3: cannot set '%s'", lua_tostring(L, 2));
   v->v[a] = (float)luaL_checknumber(L, 3);
   return 0;
}

static int ra_vec_arith(lua_State *L, int op)
{
   float a[3], b[3], r[3];
   int av = ra_lua_tovec(L, 1, a), bv = ra_lua_tovec(L, 2, b), i;
   if (av && bv)
   {
      for (i = 0; i < 3; i++)
         r[i] = op == 0 ? a[i] + b[i] : op == 1 ? a[i] - b[i] : a[i] * b[i];
   }
   else if (av && lua_isnumber(L, 2) && (op == 2 || op == 3))
   {
      float s = (float)lua_tonumber(L, 2);
      for (i = 0; i < 3; i++) r[i] = op == 2 ? a[i] * s : a[i] / s;
   }
   else if (bv && lua_isnumber(L, 1) && op == 2)
   {
      float s = (float)lua_tonumber(L, 1);
      for (i = 0; i < 3; i++) r[i] = b[i] * s;
   }
   else return luaL_error(L, "Vector3: bad operands");
   ra_lua_push_vec(L, r[0], r[1], r[2]);
   return 1;
}
static int ra_vec_add(lua_State *L) { return ra_vec_arith(L, 0); }
static int ra_vec_sub(lua_State *L) { return ra_vec_arith(L, 1); }
static int ra_vec_mul(lua_State *L) { return ra_vec_arith(L, 2); }
static int ra_vec_div(lua_State *L) { return ra_vec_arith(L, 3); }
static int ra_vec_unm(lua_State *L)
{
   float a[3];
   if (!ra_lua_tovec(L, 1, a)) return luaL_error(L, "Vector3: bad operand");
   ra_lua_push_vec(L, -a[0], -a[1], -a[2]);
   return 1;
}
static int ra_vec_eq(lua_State *L)
{
   float a[3], b[3];
   lua_pushboolean(L, ra_lua_tovec(L, 1, a) && ra_lua_tovec(L, 2, b)
                      && a[0] == b[0] && a[1] == b[1] && a[2] == b[2]);
   return 1;
}
static int ra_vec_tostring(lua_State *L)
{
   float a[3];
   ra_lua_tovec(L, 1, a);
   lua_pushfstring(L, "(%f, %f, %f)", (double)a[0], (double)a[1], (double)a[2]);
   return 1;
}

/* Vector3(x, y, z) / Vector2(x, y) and their statics */
static int ra_vec_new(lua_State *L)
{
   /* called as Vector3(...): arg 1 is the class table */
   ra_lua_push_vec(L, (float)luaL_optnumber(L, 2, 0), (float)luaL_optnumber(L, 3, 0),
                   (float)luaL_optnumber(L, 4, 0));
   return 1;
}
static int ra_vec_class_index(lua_State *L)
{
   const char *k = luaL_checkstring(L, 2);
   if (!strcmp(k, "zero"))    { ra_lua_push_vec(L, 0, 0, 0); return 1; }
   if (!strcmp(k, "one"))     { ra_lua_push_vec(L, 1, 1, 1); return 1; }
   if (!strcmp(k, "up"))      { ra_lua_push_vec(L, 0, 1, 0); return 1; }
   if (!strcmp(k, "down"))    { ra_lua_push_vec(L, 0, -1, 0); return 1; }
   if (!strcmp(k, "left"))    { ra_lua_push_vec(L, -1, 0, 0); return 1; }
   if (!strcmp(k, "right"))   { ra_lua_push_vec(L, 1, 0, 0); return 1; }
   if (!strcmp(k, "forward")) { ra_lua_push_vec(L, 0, 0, 1); return 1; }
   if (!strcmp(k, "back"))    { ra_lua_push_vec(L, 0, 0, -1); return 1; }
   return luaL_error(L, "Vector3: no static '%s'", k);
}

/* --------------------------------------------------------------- Color */

static int ra_col_index(lua_State *L)
{
   RaUCol *c = (RaUCol *)luaL_checkudata(L, 1, RA_MT_COL);
   const char *k = luaL_checkstring(L, 2);
   if (!strcmp(k, "r")) { lua_pushnumber(L, c->v[0]); return 1; }
   if (!strcmp(k, "g")) { lua_pushnumber(L, c->v[1]); return 1; }
   if (!strcmp(k, "b")) { lua_pushnumber(L, c->v[2]); return 1; }
   if (!strcmp(k, "a")) { lua_pushnumber(L, c->v[3]); return 1; }
   return luaL_error(L, "Color: no member '%s'", k);
}
static int ra_col_newindex(lua_State *L)
{
   RaUCol *c = (RaUCol *)luaL_checkudata(L, 1, RA_MT_COL);
   const char *k = luaL_checkstring(L, 2);
   float v = (float)luaL_checknumber(L, 3);
   if      (!strcmp(k, "r")) c->v[0] = v;
   else if (!strcmp(k, "g")) c->v[1] = v;
   else if (!strcmp(k, "b")) c->v[2] = v;
   else if (!strcmp(k, "a")) c->v[3] = v;
   else return luaL_error(L, "Color: cannot set '%s'", k);
   return 0;
}
static int ra_col_eq(lua_State *L)
{
   RaUCol *a = (RaUCol *)luaL_testudata(L, 1, RA_MT_COL), *b = (RaUCol *)luaL_testudata(L, 2, RA_MT_COL);
   lua_pushboolean(L, a && b && !memcmp(a->v, b->v, sizeof(a->v)));
   return 1;
}
static int ra_col_new(lua_State *L)
{
   ra_lua_push_col(L, (float)luaL_optnumber(L, 2, 0), (float)luaL_optnumber(L, 3, 0),
                   (float)luaL_optnumber(L, 4, 0), (float)luaL_optnumber(L, 5, 1));
   return 1;
}
static int ra_col_class_index(lua_State *L)
{
   const char *k = luaL_checkstring(L, 2);
   if (!strcmp(k, "white")) { ra_lua_push_col(L, 1, 1, 1, 1); return 1; }
   if (!strcmp(k, "black")) { ra_lua_push_col(L, 0, 0, 0, 1); return 1; }
   if (!strcmp(k, "red"))   { ra_lua_push_col(L, 1, 0, 0, 1); return 1; }
   if (!strcmp(k, "clear")) { ra_lua_push_col(L, 0, 0, 0, 0); return 1; }
   return luaL_error(L, "Color: no static '%s'", k);
}

/* ------------------------------------------------- PVector3 (reference) */

static float *ra_ref_target(lua_State *L, RaURef *r)
{
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in;
   switch (r->kind)
   {
      case RA_REF_CAMROT: return rt->st.cam_rot;
      case RA_REF_BDSIZE: return rt->st.bd_size;
      case RA_REF_BDOFS:  return rt->st.bd_ofs;
      case RA_REF_CLIP:   return rt->st.clip;
      case RA_REF_DUMMY:  return r->dummy;
      case RA_REF_ZAPOFS: return rt->st.zapper_ofs;
      default: break;
   }
   in = ra_lua_inst(rt, r->gen, r->li);
   if (in == &RA_LUA_DEAD) return r->dummy;   /* stale: a private sink */
   switch (r->kind)
   {
      case RA_REF_OFF: return in->off;
      case RA_REF_ROT: return in->rot;
      case RA_REF_SCL: return in->scl;
      case RA_REF_PIV: return in->piv;
   }
   return r->dummy;
}

static void ra_ref_written(lua_State *L, RaURef *r, const float before[4], const float *t)
{
   Ra3dLua *rt = ra_lua_rt(L);
   if (r->kind == RA_REF_CAMROT)
   {
      rt->st.cam_set = 1;
      if (memcmp(before, t, sizeof(float) * 3)) rt->st.cam_gen++;
   }
}

static int ra_ref_index(lua_State *L)
{
   RaURef *r = (RaURef *)luaL_checkudata(L, 1, RA_MT_REF);
   float *t = ra_ref_target(L, r);
   int a = ra_lua_axis(L, 2), n = r->kind == RA_REF_CLIP ? 4 : 3;
   const char *k;
   if (a >= 0 && a < n) { lua_pushnumber(L, t[a]); return 1; }
   k = lua_tostring(L, 2);
   if (!k) return luaL_error(L, "PVector3: bad index");
   if (!strcmp(k, "content")) { ra_lua_push_vec(L, t[0], t[1], t[2]); return 1; }
   if (!strcmp(k, "magnitude"))
   { lua_pushnumber(L, sqrt((double)t[0]*t[0] + (double)t[1]*t[1] + (double)t[2]*t[2])); return 1; }
   return luaL_error(L, "PVector3: no member '%s'", k);
}

static int ra_ref_newindex(lua_State *L)
{
   RaURef *r = (RaURef *)luaL_checkudata(L, 1, RA_MT_REF);
   float *t = ra_ref_target(L, r), before[4];
   int a = ra_lua_axis(L, 2), n = r->kind == RA_REF_CLIP ? 4 : 3;
   memcpy(before, t, sizeof(float) * (size_t)n);
   if (a >= 0 && a < n) t[a] = (float)luaL_checknumber(L, 3);
   else
   {
      const char *k = lua_tostring(L, 2);
      float v[3];
      if (!k || strcmp(k, "content")) return luaL_error(L, "PVector3: cannot set '%s'", k ? k : "?");
      if (!ra_lua_tovec(L, 3, v)) return luaL_error(L, "PVector3.content: not a vector");
      memcpy(t, v, sizeof(v));
   }
   ra_ref_written(L, r, before, t);
   return 0;
}

/* -------------------------------------------------------------- CData */

static int ra_cdata_index(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_CDATA);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   lua_Number i = luaL_checknumber(L, 2);
   int ii = (int)floor(i);
   if (ii < 0 || ii > 7) return luaL_error(L, "CData: index %d out of range", ii);
   if (in == &RA_LUA_DEAD || in->shape >= rt->prof->shapes.n) { lua_pushnumber(L, 0); return 1; }
   lua_pushnumber(L, rt->prof->shapes.v[in->shape].cdata[ii]);
   return 1;
}
static int ra_cdata_newindex(lua_State *L) { (void)L; return 0; }   /* accepted, dropped */

/* ------------------------------------------------------- dummy matrix */

static int ra_mat_index(lua_State *L) { lua_pushnumber(L, 0); return 1; }
static int ra_mat_newindex(lua_State *L) { (void)L; return 0; }

/* --------------------------------------------------------------- List */

static int ra_list_index(lua_State *L)
{
   RaUList *u = (RaUList *)luaL_checkudata(L, 1, RA_MT_LIST);
   if (lua_type(L, 2) == LUA_TNUMBER)
   {
      lua_Number n = lua_tonumber(L, 2);
      lua_Integer i = (lua_Integer)floor(n);
      if (i < 0 || (uint32_t)i >= u->n)
         return luaL_error(L, "List: index %d out of range (Count %d)", (int)i, (int)u->n);
      if (u->kind == RA_LIST_SHAPE)
      {
         Ra3dLua *rt = ra_lua_rt(L);
         if (u->gen != rt->gen) return luaL_error(L, "List: stale");
         ra_lua_push_shape(L, u->items[i]);
      }
      else ra_lua_push_pshape(L, u->items[i]);
      return 1;
   }
   {
      const char *k = luaL_checkstring(L, 2);
      if (!strcmp(k, "Count")) { lua_pushinteger(L, u->n); return 1; }
      return luaL_error(L, "List: no member '%s'", k);
   }
}

static RaUList *ra_lua_new_list(lua_State *L, uint32_t kind, uint32_t n)
{
   Ra3dLua *rt = ra_lua_rt(L);
   RaUList *u = (RaUList *)lua_newuserdata(L, sizeof(RaUList) + (size_t)(n ? n : 1) * sizeof(uint32_t));
   u->kind = kind; u->gen = rt->gen; u->n = 0;
   luaL_setmetatable(L, RA_MT_LIST);
   return u;
}

/* -------------------------------------------- Pattern3D (frame copy) */

static int ra_shape_getpos(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   float p[3], o[3];
   if (lua_gettop(L) >= 2) { if (!ra_lua_tovec(L, 2, p)) return luaL_error(L, "GetPos: bad pivot"); }
   else memcpy(p, in->piv, sizeof(p));
   ra_lua_getpos(rt, in, p, o);
   ra_lua_push_vec(L, o[0], o[1], o[2]);
   return 1;
}

static int ra_shape_overlap(lua_State *L)
{
   RaUShape *a = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE);
   RaUShape *b = (RaUShape *)luaL_checkudata(L, 2, RA_MT_SHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   const Ra3dGeoRegion *ra = ra_lua_region(rt, ra_lua_inst(rt, a->gen, a->li));
   const Ra3dGeoRegion *rb = ra_lua_region(rt, ra_lua_inst(rt, b->gen, b->li));
   int d = (int)luaL_optinteger(L, 3, 0);
   /* Shape.SimpleOverlap, strict */
   lua_pushboolean(L, ra->px0 < rb->px1 + d && ra->px1 + d > rb->px0 &&
                      ra->py0 < rb->py1 + d && ra->py1 + d > rb->py0);
   return 1;
}

static int ra_shape_getdeform(lua_State *L) { ra_lua_push_vec(L, 0, 0, 0); return 1; }

static int ra_shape_containstag(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   size_t n; const char *t = luaL_checklstring(L, 2, &n);
   lua_pushboolean(L, in != &RA_LUA_DEAD && ra_lua_shape_has_tag(rt->prof, in->shape, t, n));
   return 1;
}

static int ra_shape_index(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   const Ra3dGeoRegion *r = ra_lua_region(rt, in);
   const char *k = luaL_checkstring(L, 2);
   float sz = ra_lua_sizez(rt, in);
   switch (k[0])
   {
   case 'A':
      if (!strcmp(k, "Alpha")) { lua_pushnumber(L, in->alpha); return 1; }
      break;
   case 'B':
      if (!strcmp(k, "BottomLeft")) { ra_lua_push_vec(L, r->px0, (float)(RA3D_UNITY_H - r->py1), -sz / 2); return 1; }
      if (!strcmp(k, "BL"))         { ra_lua_push_vec(L, r->px0, (float)(RA3D_UNITY_H - r->py1 - 1), -sz / 2); return 1; }
      if (!strcmp(k, "Bg"))         { lua_pushboolean(L, (r->flags & 1) != 0); return 1; }
      break;
   case 'C':
      if (!strcmp(k, "CData"))
      {
         RaUShape *c = (RaUShape *)lua_newuserdata(L, sizeof(*c));
         *c = *u; luaL_setmetatable(L, RA_MT_CDATA); return 1;
      }
      if (!strcmp(k, "CastShadow")) { lua_pushboolean(L, in->cast); return 1; }
      if (!strcmp(k, "ContainsTag")) { lua_pushcfunction(L, ra_shape_containstag); return 1; }
      break;
   case 'D':
      if (!strcmp(k, "DeformAmp") || !strcmp(k, "DeformPivot"))
      { ra_lua_push_ref(L, RA_REF_DUMMY, u->gen, u->li); return 1; }
      if (!strcmp(k, "DeformSpeed") || !strcmp(k, "DeformOffset"))
      { lua_newuserdata(L, 1); luaL_setmetatable(L, RA_MT_MAT); return 1; }
      break;
   case 'E':
      if (!strcmp(k, "Enable")) { lua_pushboolean(L, in->style > 0); return 1; }
      break;
   case 'G':
      if (!strcmp(k, "GetPos"))    { lua_pushcfunction(L, ra_shape_getpos); return 1; }
      if (!strcmp(k, "GetDeform")) { lua_pushcfunction(L, ra_shape_getdeform); return 1; }
      break;
   case 'I':
      if (!strcmp(k, "Index")) goto idx;
      break;
   case 'L':
      if (!strcmp(k, "Layer")) { lua_pushinteger(L, in->layer); return 1; }
      break;
   case 'O':
      if (!strcmp(k, "Offset"))  { ra_lua_push_ref(L, RA_REF_OFF, u->gen, u->li); return 1; }
      if (!strcmp(k, "Overlap")) { lua_pushcfunction(L, ra_shape_overlap); return 1; }
      if (!strcmp(k, "OriPos"))  { ra_lua_push_vec(L, r->px0, (float)(RA3D_UNITY_H - r->py1), -sz / 2); return 1; }
      break;
   case 'P':
      if (!strcmp(k, "Pivot"))   { ra_lua_push_ref(L, RA_REF_PIV, u->gen, u->li); return 1; }
      if (!strcmp(k, "Palette")) { lua_pushinteger(L, in->custom_pal >= 0 ? in->custom_pal : r->pal); return 1; }
      if (!strcmp(k, "Pos"))
      { float o[3]; ra_lua_getpos(rt, in, in->piv, o); ra_lua_push_vec(L, o[0], o[1], o[2]); return 1; }
      break;
   case 'R':
      if (!strcmp(k, "Rot"))         { ra_lua_push_ref(L, RA_REF_ROT, u->gen, u->li); return 1; }
      if (!strcmp(k, "RecvShadow"))  { lua_pushboolean(L, in->recv); return 1; }
      if (!strcmp(k, "RenderStyle")) { lua_pushinteger(L, in->style); return 1; }
      break;
   case 'S':
      if (!strcmp(k, "Scale"))   { ra_lua_push_ref(L, RA_REF_SCL, u->gen, u->li); return 1; }
      if (!strcmp(k, "Shape2D"))
      {
         RaUShape *c = (RaUShape *)lua_newuserdata(L, sizeof(*c));
         *c = *u; luaL_setmetatable(L, RA_MT_SHAPE2); return 1;
      }
      if (!strcmp(k, "Sp"))      { lua_pushboolean(L, (r->flags & 1) == 0); return 1; }
      if (!strcmp(k, "Size")) goto size;
      break;
   case 'T':
      if (!strcmp(k, "TopRight")) { ra_lua_push_vec(L, r->px1, (float)(RA3D_UNITY_H - r->py0), sz / 2); return 1; }
      if (!strcmp(k, "TR"))       { ra_lua_push_vec(L, r->px1, (float)(RA3D_UNITY_H - r->py0 - 1), sz / 2); return 1; }
      if (!strcmp(k, "TagStr"))
      {
         if (in != &RA_LUA_DEAD && in->shape < rt->prof->shapes.n)
         {
            const Ra3dShape3D *sh = &rt->prof->shapes.v[in->shape];
            lua_pushlstring(L, rt->prof->tagpool.v + sh->tag_off, sh->tag_len);
         }
         else lua_pushstring(L, "");
         return 1;
      }
      break;
   case 'U':
      if (!strcmp(k, "UI")) { lua_pushboolean(L, in->layer == 1); return 1; }
      break;
   default:
      if (!strcmp(k, "size"))
      {
      size:
         ra_lua_push_vec(L, (float)(r->px1 - r->px0 + 1), (float)(r->py1 - r->py0 + 1), sz);
         return 1;
      }
      if (!strcmp(k, "tSize")) { ra_lua_push_vec(L, r->tw, r->th, 0); return 1; }
      if (!strcmp(k, "index"))
      {
      idx:
         lua_pushinteger(L, (in != &RA_LUA_DEAD && in->shape < rt->prof->shapes.n)
                            ? rt->prof->shapes.v[in->shape].index : 0);
         return 1;
      }
      if (!strcmp(k, "refPattern3D"))
      {
         if (in == &RA_LUA_DEAD || in->shape >= rt->prof->shapes.n) lua_pushnil(L);
         else ra_lua_push_pshape(L, in->shape);
         return 1;
      }
      if (!strcmp(k, "refPattern"))
      {  /* only .tSize is ever read off it: the profile Pattern3D answers that */
         if (in == &RA_LUA_DEAD || in->shape >= rt->prof->shapes.n) lua_pushnil(L);
         else ra_lua_push_pshape(L, in->shape);
         return 1;
      }
      break;
   }
   return luaL_error(L, "Pattern3D: no member '%s'", k);
}

static int ra_shape_newindex(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   const char *k = luaL_checkstring(L, 2);
   if (!strcmp(k, "Enable"))       { in->style = lua_toboolean(L, 3) ? 1 : 0; return 0; }
   if (!strcmp(k, "Palette"))      { in->custom_pal = (int32_t)floor(luaL_checknumber(L, 3)); return 0; }
   if (!strcmp(k, "UI"))           { if (lua_toboolean(L, 3)) in->layer = 1; return 0; }
   if (!strcmp(k, "Layer"))        { int v = (int)luaL_checkinteger(L, 3); in->layer = (uint8_t)(v >= 0 && v < 6 ? v : 2); return 0; }
   if (!strcmp(k, "Alpha"))        { in->alpha = (float)luaL_checknumber(L, 3); return 0; }
   if (!strcmp(k, "CastShadow"))   { in->cast = (uint8_t)lua_toboolean(L, 3); return 0; }
   if (!strcmp(k, "RecvShadow"))   { in->recv = (uint8_t)lua_toboolean(L, 3); return 0; }
   if (!strcmp(k, "RenderStyle"))  { in->style = (int32_t)luaL_checkinteger(L, 3); return 0; }
   return luaL_error(L, "Pattern3D: cannot set '%s'", k);
}

/* ------------------------------------------------- Shape (shape2D) */

static int ra_shape2_index(lua_State *L)
{
   RaUShape *u = (RaUShape *)luaL_checkudata(L, 1, RA_MT_SHAPE2);
   Ra3dLua *rt = ra_lua_rt(L);
   RaLuaInst *in = ra_lua_inst(rt, u->gen, u->li);
   const Ra3dGeoRegion *r = ra_lua_region(rt, in);
   const char *k = luaL_checkstring(L, 2);
   const Ra3dPattern *pa = (r->pattern < rt->prof->patterns.n) ? &rt->prof->patterns.v[r->pattern] : NULL;
   if (!strcmp(k, "Completed")) { lua_pushboolean(L, pa && r->idents == pa->ident_count); return 1; }
   if (!strcmp(k, "AtBorder") || !strcmp(k, "Inside"))
   {
      int inside = r->px0 > 0 && r->px1 < 255 && r->py0 > 0 && r->py1 < 239;
      lua_pushboolean(L, k[0] == 'A' ? !inside : inside);
      return 1;
   }
   if (!strcmp(k, "hidden") || !strcmp(k, "Hidden")) { lua_pushboolean(L, (r->flags & 2) != 0); return 1; }
   if (!strcmp(k, "Size"))  { ra_lua_push_vec(L, (float)(r->px1 - r->px0 + 1), (float)(r->py1 - r->py0 + 1), 0); return 1; }
   if (!strcmp(k, "Start")) { ra_lua_push_vec(L, r->px0, r->py0, 0); return 1; }
   if (!strcmp(k, "End"))   { ra_lua_push_vec(L, r->px1, r->py1, 0); return 1; }
   if (!strcmp(k, "BottomLeft")) { ra_lua_push_vec(L, r->px0, (float)(RA3D_UNITY_H - r->py1 - 1), 0); return 1; }
   if (!strcmp(k, "TopRight"))   { ra_lua_push_vec(L, r->px1, (float)(RA3D_UNITY_H - r->py0 - 1), 0); return 1; }
   if (!strcmp(k, "Bg") || !strcmp(k, "bg")) { lua_pushboolean(L, (r->flags & 1) != 0); return 1; }
   if (!strcmp(k, "Palette") || !strcmp(k, "palIndex")) { lua_pushinteger(L, r->pal); return 1; }
   if (!strcmp(k, "tStart") || !strcmp(k, "TStart")) { ra_lua_push_vec(L, r->tx0, r->ty0, 0); return 1; }
   if (!strcmp(k, "tEnd") || !strcmp(k, "TEnd")) { ra_lua_push_vec(L, r->tx0 + r->tw - 1, r->ty0 + r->th - 1, 0); return 1; }
   if (!strcmp(k, "tSize") || !strcmp(k, "TSize")) { ra_lua_push_vec(L, r->tw, r->th, 0); return 1; }
   if (!strcmp(k, "id")) { lua_pushinteger(L, (lua_Integer)(in->region + 1)); return 1; }
   if (!strcmp(k, "Count") || !strcmp(k, "InsCount")) { lua_pushinteger(L, pa ? pa->shape_count : 1); return 1; }
   if (!strcmp(k, "TileCount")) { lua_pushinteger(L, (lua_Integer)r->tw * r->th); return 1; }
   return luaL_error(L, "Shape: no member '%s'", k);
}

/* ------------------------------------ profile Pattern3D (refPattern3D) */

static int ra_pshape_index(lua_State *L)
{
   RaUPShape *u = (RaUPShape *)luaL_checkudata(L, 1, RA_MT_PSHAPE);
   Ra3dLua *rt = ra_lua_rt(L);
   const char *k = luaL_checkstring(L, 2);
   const Ra3dShape3D *sh = u->shape < rt->prof->shapes.n ? &rt->prof->shapes.v[u->shape] : NULL;
   const Ra3dPattern *pa = sh ? &rt->prof->patterns.v[sh->pattern] : NULL;
   if (!sh) return luaL_error(L, "Pattern3D: invalid");
   if (!strcmp(k, "tSize")) { ra_lua_push_vec(L, pa->w, pa->h, 0); return 1; }
   if (!strcmp(k, "index") || !strcmp(k, "Index")) { lua_pushinteger(L, sh->index); return 1; }
   if (!strcmp(k, "refPattern") || !strcmp(k, "refPattern3D")) { lua_pushvalue(L, 1); return 1; }
   if (!strcmp(k, "TagStr")) { lua_pushlstring(L, rt->prof->tagpool.v + sh->tag_off, sh->tag_len); return 1; }
   if (!strcmp(k, "Enable")) { lua_pushboolean(L, sh->render_style > 0); return 1; }
   if (!strcmp(k, "CData"))  { lua_newtable(L); { int i; for (i = 0; i < 8; i++) { lua_pushnumber(L, sh->cdata[i]); lua_rawseti(L, -2, i); } } return 1; }
   return luaL_error(L, "Pattern3D(profile): no member '%s'", k);
}
static int ra_pshape_eq(lua_State *L)
{
   RaUPShape *a = (RaUPShape *)luaL_testudata(L, 1, RA_MT_PSHAPE), *b = (RaUPShape *)luaL_testudata(L, 2, RA_MT_PSHAPE);
   lua_pushboolean(L, a && b && a->shape == b->shape);
   return 1;
}

/* --------------------------------------------- Frame:AddNewShape (1b) */

/* into the frame's extra atlas (Ra3dGeoFrame.xpx, pixel values,
 * shared with the textured Pattern3Ds), so one index space covers both. */
static uint32_t ra_lua_xatlas_add(Ra3dLua *rt, const uint8_t chr[16])
{
   Ra3dGeoFrame *g = rt->g;
   uint8_t *dst;
   int y, x;
   if (!g || !ra3d_grow((void **)&g->xpx, &g->xpx_cap, (g->xpx_n + 1) * 64, 1))
      return 0xFFFFFFFFu;
   dst = g->xpx + (size_t)g->xpx_n * 64;
   for (y = 0; y < 8; y++)
      for (x = 0; x < 8; x++)
         dst[y * 8 + x] = (uint8_t)((((chr[8 + y] >> (7 - x)) & 1) << 1) | ((chr[y] >> (7 - x)) & 1));
   rt->st.xatlas_n++;
   return g->xpx_n++;
}

/* the palette GROUP of an inserted shape. 3dSen lays the tiles
 * as sprite tiles with tile.palette = pal - 4 and adds 4 back
 * for a sprite: the argument is an ABSOLUTE index into the
 * 16-table palette (0-15), not a sprite palette. Ours masked it to 0-7, so a
 * script's table 8-15 (Punch-Out's mac_fixcolor tables) collapsed onto the
 * frame's. AddRef's pal 0 IS table 0 in 3dSen too; the referee only looks
 * right there because his Pattern3Ds carry a Direct-colour texture. */
static int ra_lua_ins_group(int pal) { return pal & 15; }

/* Frame.AddNewShape(refPattern3D.pattern, pos, pal, refPattern3D.index):
 * the pattern's AUTHORED tiles laid at (8j, 8i) as sprite tiles of palette
 * pal - 4, bound to the pattern, Offset += (pos.x, pos.y - HeightInPixel + 8h,
 * pos.z) with HeightInPixel = RA3D_UNITY_H,
 * only variant `index` enabled; not scriptable. Returns that variant. */
static int ra_frame_addnewshape(lua_State *L, int base)
{
   Ra3dLua *rt = ra_lua_rt(L);
   RaUPShape *ps = (RaUPShape *)luaL_testudata(L, base, RA_MT_PSHAPE);
   const Ra3dProfile *p = rt->prof;
   const Ra3dShape3D *sh;
   const Ra3dPattern *pa;
   float pos[3];
   int pal;
   RaLuaInst *in;
   Ra3dGeoRegion *rg;
   uint32_t c;
   int32_t x0 = 1 << 20, y0 = 1 << 20, x1 = -(1 << 20), y1 = -(1 << 20);
   if (!ps)
   {
      RaUShape *fs = (RaUShape *)luaL_testudata(L, base, RA_MT_SHAPE);
      if (!fs) return luaL_error(L, "AddNewShape: expected a Pattern3D");
      in = ra_lua_inst(rt, fs->gen, fs->li);
      if (in == &RA_LUA_DEAD) return luaL_error(L, "AddNewShape: stale Pattern3D");
      lua_pushinteger(L, (lua_Integer)in->shape);   /* treated as its refPattern3D */
      ps = NULL;
   }
   {
      uint32_t shape = ps ? ps->shape : (uint32_t)lua_tointeger(L, -1);
      if (!ps) lua_pop(L, 1);
      if (shape >= p->shapes.n) return luaL_error(L, "AddNewShape: bad pattern");
      sh = &p->shapes.v[shape];
      pa = &p->patterns.v[sh->pattern];
      if (!ra_lua_tovec(L, base + 1, pos)) return luaL_error(L, "AddNewShape: bad position");
      pal = (int)floor(luaL_checknumber(L, base + 2));
      if (!ra_lua_grow((void **)&rt->li, &rt->cap_li, rt->nli + 1, sizeof(RaLuaInst)) ||
          !ra_lua_grow((void **)&rt->rg, &rt->cap_rg, rt->nrg + 1, sizeof(Ra3dGeoRegion)))
         return luaL_error(L, "AddNewShape: out of memory");
      in = &rt->li[rt->nli];
      memset(in, 0, sizeof(*in));
      memcpy(in->off, sh->offset, sizeof(in->off));
      memcpy(in->rot, sh->rot,    sizeof(in->rot));
      memcpy(in->scl, sh->scale,  sizeof(in->scl));
      memcpy(in->piv, sh->pivot,  sizeof(in->piv));
      in->alpha = sh->alpha; in->style = 1;           /* pattern3D.Enable = true */
      in->custom_pal = -1; in->layer = sh->layer;
      in->cast = !sh->tag_nocast; in->recv = !sh->tag_norecv;
      in->scriptable = 0; in->inst = 0xFFFFFFFFu; in->shape = shape;
      in->region = rt->nrg; in->ins_pal = pal;
      in->off[0] += pos[0];
      in->off[1] += pos[1] - (float)RA3D_UNITY_H + (float)(pa->h * 8);
      in->off[2] += pos[2];
   }
   /* the region: the authored cells' opaque box (Tile2D start/end) */
   for (c = 0; c < pa->cell_count; c++)
   {
      const Ra3dPatCell *cl = &p->cells.v[pa->cell_first + c];
      const Ra3dVariant *v = &p->vars.v[p->cellvars.v[cl->var_first]];
      int bx0 = 7, by0 = 7, bx1 = 0, by1 = 0, yy, xx;
      for (yy = 0; yy < 8; yy++)
      {
         uint8_t m = (uint8_t)(v->chr[yy] | v->chr[8 + yy]);
         if (!m) continue;
         if (yy < by0) by0 = yy;
         if (yy > by1) by1 = yy;
         for (xx = 0; xx < 8; xx++)
            if (m & (0x80u >> xx)) { if (xx < bx0) bx0 = xx; if (xx > bx1) bx1 = xx; }
      }
      if (v->fx) { int q = bx0; bx0 = 7 - bx1; bx1 = 7 - q; }
      if (v->fy) { int q = by0; by0 = 7 - by1; by1 = 7 - q; }
      if (cl->gx * 8 + bx0 < x0) x0 = cl->gx * 8 + bx0;
      if (cl->gy * 8 + by0 < y0) y0 = cl->gy * 8 + by0;
      if (cl->gx * 8 + bx1 > x1) x1 = cl->gx * 8 + bx1;
      if (cl->gy * 8 + by1 > y1) y1 = cl->gy * 8 + by1;
   }
   if (x1 < x0) { x0 = 0; y0 = 0; x1 = pa->w * 8 - 1; y1 = pa->h * 8 - 1; }
   rg = &rt->rg[rt->nrg++];
   memset(rg, 0, sizeof(*rg));
   rg->px0 = (int16_t)x0; rg->py0 = (int16_t)y0; rg->px1 = (int16_t)x1; rg->py1 = (int16_t)y1;
   rg->tw = pa->w; rg->th = pa->h;
   rg->idents = (uint16_t)pa->ident_count;
   rg->pal = (uint8_t)ra_lua_ins_group(pal);
   rg->flags = 0;
   rg->pattern = sh->pattern;
   rt->nli++;
   rt->st.inserted++;
   ra_lua_push_shape(L, rt->nli - 1);
   return 1;
}

/* ----------------------------------------------- the global objects */

static int ra_obj_base(lua_State *L)
{  /* `Frame:GetShape(i)` passes the object first; `Pattern.Get...(t)` does not */
   return luaL_testudata(L, 1, RA_MT_OBJ) ? 2 : 1;
}

static int ra_fn_frame_getshapewithtag(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   size_t n; const char *t = luaL_checklstring(L, b, &n);
   uint32_t i;
   for (i = 0; i < rt->nscr; i++)
      if (ra_lua_shape_has_tag(rt->prof, rt->li[rt->scr[i]].shape, t, n))
      { ra_lua_push_shape(L, rt->scr[i]); return 1; }
   lua_pushnil(L);
   return 1;
}
static int ra_fn_frame_getshapeswithtag(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   size_t n; const char *t = luaL_checklstring(L, b, &n);
   uint32_t i;
   RaUList *u = ra_lua_new_list(L, RA_LIST_SHAPE, rt->nscr);
   for (i = 0; i < rt->nscr; i++)
      if (ra_lua_shape_has_tag(rt->prof, rt->li[rt->scr[i]].shape, t, n))
         u->items[u->n++] = rt->scr[i];
   return 1;
}
static int ra_fn_frame_getshape(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   lua_Integer i = (lua_Integer)floor(luaL_checknumber(L, b));
   if (i < 0 || (uint32_t)i >= rt->nscr) return luaL_error(L, "GetShape: index %d out of range", (int)i);
   ra_lua_push_shape(L, rt->scr[i]);
   return 1;
}
static int ra_fn_frame_addnewshape(lua_State *L) { return ra_frame_addnewshape(L, ra_obj_base(L)); }

static int ra_fn_pattern_getwithtag(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   size_t n; const char *t = luaL_checklstring(L, b, &n);
   uint32_t i;
   for (i = 0; i < rt->prof->shapes.n; i++)
      if (ra_lua_shape_has_tag(rt->prof, i, t, n)) { ra_lua_push_pshape(L, i); return 1; }
   lua_pushnil(L);
   return 1;
}
static int ra_fn_pattern_getswithtag(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   size_t n; const char *t = luaL_checklstring(L, b, &n);
   uint32_t i, cnt = 0;
   RaUList *u;
   for (i = 0; i < rt->prof->shapes.n; i++)
      if (ra_lua_shape_has_tag(rt->prof, i, t, n)) cnt++;
   u = ra_lua_new_list(L, RA_LIST_PSHAPE, cnt);
   for (i = 0; i < rt->prof->shapes.n; i++)
      if (ra_lua_shape_has_tag(rt->prof, i, t, n)) u->items[u->n++] = i;
   return 1;
}

static int ra_fn_readmem(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   lua_Integer a = (lua_Integer)floor(luaL_checknumber(L, b));
   lua_pushinteger(L, (rt->ram && a >= 0 && a < 0x800) ? rt->ram[a] : 0);
   return 1;
}

static uint32_t ra_lua_argb_of(Ra3dLua *rt, int i)
{
   unsigned e = rt->st.pal_idx[i & 63] & 63u;
   return ra3d_nes_rgb(rt->k, rt->scene ? rt->scene->RgbPalette : NULL, e);
}
static int ra_fn_framecolor(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   uint32_t c = ra_lua_argb_of(rt, (int)luaL_checkinteger(L, b));
   ra_lua_push_col(L, ((c >> 16) & 255) / 255.0f, ((c >> 8) & 255) / 255.0f, (c & 255) / 255.0f, 1.0f);
   return 1;
}
static int ra_fn_framecolorindex(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   lua_pushinteger(L, rt->st.pal_idx[luaL_checkinteger(L, b) & 63]);
   return 1;
}
static int ra_fn_setcolorindex(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   lua_Integer i = luaL_checkinteger(L, b);
   lua_Integer v = (lua_Integer)floor(luaL_checknumber(L, b + 1));
   rt->st.pal_idx[i & 63] = (uint8_t)(v & 63);
   return 0;
}
static int ra_fn_noti(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int b = ra_obj_base(L);
   ra_lua_logf(rt, "3dlua: NotiCenter.Notify \"%s\"", luaL_optstring(L, b, ""));
   return 0;
}
static int ra_fn_noop(lua_State *L) { (void)L; return 0; }
/* Setting:GetInputType(port): 3dSen's Gamepads.InputType (0 Keyboard,
 * 1 Controller). The light-gun profiles (Duck Hunt, Hogan's Alley, Wild
 * Gunman) save it in Start(), set Controller and restore it in End(); the
 * frontend owns our ports, so this answers Controller and SetInputType is a
 * no-op. Without the pair those profiles' main script died in Start(). */
static int ra_fn_getinputtype(lua_State *L) { (void)L; lua_pushinteger(L, 1); return 1; }

static int ra_fn_print(lua_State *L)
{
   Ra3dLua *rt = ra_lua_rt(L);
   int n = lua_gettop(L), i;
   luaL_Buffer bf;
   luaL_buffinit(L, &bf);
   for (i = 1; i <= n; i++)
   {
      luaL_tolstring(L, i, NULL);
      luaL_addvalue(&bf);
      if (i < n) luaL_addchar(&bf, '\t');
   }
   luaL_pushresult(&bf);
   ra_lua_logf(rt, "3dlua: print %s", lua_tostring(L, -1));
   return 0;
}

static int ra_obj_index(lua_State *L)
{
   RaUObj *o = (RaUObj *)luaL_checkudata(L, 1, RA_MT_OBJ);
   Ra3dLua *rt = ra_lua_rt(L);
   Ra3dLuaState *st = &rt->st;
   const char *k;
   if (o->kind == RA_OBJ_LAYERS || o->kind == RA_OBJ_PADS)
   {
      lua_Integer n = (lua_Integer)floor(luaL_checknumber(L, 2));
      if (o->kind == RA_OBJ_LAYERS && (n < 0 || n > 5)) return luaL_error(L, "Layer[%d] out of range", (int)n);
      ra_lua_push_obj(L, o->kind == RA_OBJ_LAYERS ? RA_OBJ_LAYERP : RA_OBJ_PAD, (int32_t)n);
      return 1;
   }
   k = luaL_checkstring(L, 2);
   switch (o->kind)
   {
   case RA_OBJ_FRAME:
      if (!strcmp(k, "GetShapeWithTag"))  { lua_pushcfunction(L, ra_fn_frame_getshapewithtag); return 1; }
      if (!strcmp(k, "GetShapesWithTag")) { lua_pushcfunction(L, ra_fn_frame_getshapeswithtag); return 1; }
      if (!strcmp(k, "GetShape"))         { lua_pushcfunction(L, ra_fn_frame_getshape); return 1; }
      if (!strcmp(k, "shapeCount"))       { lua_pushinteger(L, rt->nscr); return 1; }
      if (!strcmp(k, "AddNewShape"))      { lua_pushcfunction(L, ra_fn_frame_addnewshape); return 1; }
      if (!strcmp(k, "frameCounter"))     { lua_getglobal(L, "frame"); return 1; }
      if (!strcmp(k, "time"))             { lua_getglobal(L, "time"); return 1; }
      break;
   case RA_OBJ_SETTING:
      if (!strcmp(k, "EmptyTile"))  { lua_pushboolean(L, st->empty_tile); return 1; }
      if (!strcmp(k, "LocalCam") || !strcmp(k, "TopDownCam")) { lua_pushboolean(L, st->localcam); return 1; }
      if (!strcmp(k, "Layer"))      { ra_lua_push_obj(L, RA_OBJ_LAYERS, 0); return 1; }
      if (!strcmp(k, "Clipping"))   { ra_lua_push_ref(L, RA_REF_CLIP, 0, 0); return 1; }
      if (!strcmp(k, "VrRuntime"))  { lua_pushinteger(L, 0); return 1; }   /* desktop: no VR halving */
      if (!strcmp(k, "SceneRatio") || !strcmp(k, "SmoothTime") || !strcmp(k, "GameSpeed"))
      { lua_pushnumber(L, 1); return 1; }
      if (!strcmp(k, "Shadow") || !strcmp(k, "BgColor")) { lua_pushboolean(L, 1); return 1; }
      if (!strcmp(k, "Light"))      { lua_getglobal(L, "Light"); return 1; }
      /* v2 Punch-Out `camera`'s v1 fallback reads these. Our frame
       * is 3dSen's desktop one: FOV 70, Scene Scale 1 (VR scale is ours). */
      if (!strcmp(k, "Fov"))        { lua_pushnumber(L, 70); return 1; }
      if (!strcmp(k, "SceneScale")) { lua_pushnumber(L, 1); return 1; }
      if (!strcmp(k, "GetInputType")) { lua_pushcfunction(L, ra_fn_getinputtype); return 1; }
      if (!strcmp(k, "SetInputType")) { lua_pushcfunction(L, ra_fn_noop); return 1; }
      break;
   case RA_OBJ_LAYERP:
      if (!strcmp(k, "CastShadow")) { lua_pushboolean(L, st->layer_cast[o->n]); return 1; }
      if (!strcmp(k, "RecvShadow")) { lua_pushboolean(L, st->layer_recv[o->n]); return 1; }
      if (!strcmp(k, "Offset"))
      {
         if (rt->prof && rt->prof->layer_set && rt->k && rt->k->profile_layers)
            lua_pushnumber(L, rt->prof->layer_off[o->n]);
         else lua_pushnumber(L, rt->k ? -rt->k->layer_z[o->n] : 0);
         return 1;
      }
      if (!strcmp(k, "Aligned"))
      { lua_pushinteger(L, (rt->prof && rt->prof->layer_set) ? rt->prof->layer_align[o->n] : 0); return 1; }
      break;
   case RA_OBJ_LIGHT:
      if (!strcmp(k, "Color"))
      { if (st->light_col_set) ra_lua_push_col(L, st->light_col[0], st->light_col[1], st->light_col[2], 1);
        else ra_lua_push_col(L, 1, 1, 1, 1); return 1; }
      if (!strcmp(k, "Direction"))
      { if (st->light_dir_set) ra_lua_push_vec(L, st->light_dir[0], st->light_dir[1], st->light_dir[2]);
        else ra_lua_push_vec(L, 1, -1, 1); return 1; }
      if (!strcmp(k, "Intensity")) { lua_pushnumber(L, 1); return 1; }
      break;
   case RA_OBJ_BACKDROP:
      if (!strcmp(k, "Enable"))     { lua_pushboolean(L, st->bd_enable); return 1; }
      if (!strcmp(k, "RecvShadow")) { lua_pushboolean(L, st->bd_recv); return 1; }
      if (!strcmp(k, "Color")) { ra_lua_push_col(L, st->bd_color[0], st->bd_color[1], st->bd_color[2], st->bd_color[3]); return 1; }
      if (!strcmp(k, "Size"))   { ra_lua_push_ref(L, RA_REF_BDSIZE, 0, 0); return 1; }
      if (!strcmp(k, "Offset")) { ra_lua_push_ref(L, RA_REF_BDOFS, 0, 0); return 1; }
      if (!strncmp(k, "Size", 4) && k[4] >= 'X' && k[4] <= 'Z' && !k[5]) { lua_pushnumber(L, st->bd_size[k[4] - 'X']); return 1; }
      if (!strncmp(k, "Ofs", 3)  && k[3] >= 'X' && k[3] <= 'Z' && !k[4]) { lua_pushnumber(L, st->bd_ofs[k[3] - 'X']); return 1; }
      break;
   case RA_OBJ_CAMERA:
      if (!strcmp(k, "Rot"))      { ra_lua_push_ref(L, RA_REF_CAMROT, 0, 0); return 1; }
      if (!strcmp(k, "Distance")) { lua_pushnumber(L, st->cam_dist); return 1; }
      /* 3dSenVR 2.0's Camera.ResetDistance =
       * 132.7964 / tan(fov/2) * SceneScale (x2 in VR). We answer the DESKTOP
       * value at FOV 70 / SceneScale 1 = 189.653, the same constant as the
       * reset pose below, because the scripted-camera home maps Distance onto our own
       * scale as zoom = 189.65 / Distance: the reset distance is identity. */
      if (!strcmp(k, "ResetDistance")) { lua_pushnumber(L, RA3D_LUA_CAM_RESET_DIST); return 1; }
      if (!strcmp(k, "Mode"))     { lua_pushinteger(L, 0); return 1; }
      if (!strcmp(k, "Target"))   { ra_lua_push_ref(L, RA_REF_DUMMY, 0, 0); return 1; }
      if (!strcmp(k, "SetTarget") || !strcmp(k, "SetFPV") || !strcmp(k, "LookAt"))
      { lua_pushcfunction(L, ra_fn_noop); return 1; }   /* FPV/follow: not in VR (Stage 2) */
      if (!strcmp(k, "FpvShape")) { lua_pushnil(L); return 1; }
      break;
   case RA_OBJ_SCRIPT:
      if (!strcmp(k, "ReadMem")) { lua_pushcfunction(L, ra_fn_readmem); return 1; }
      break;
   case RA_OBJ_PALETTE:
      if (!strcmp(k, "FrameColor"))      { lua_pushcfunction(L, ra_fn_framecolor); return 1; }
      if (!strcmp(k, "FrameColorIndex") || !strcmp(k, "GetColorIndex"))
      { lua_pushcfunction(L, ra_fn_framecolorindex); return 1; }
      if (!strcmp(k, "SetColorIndex"))   { lua_pushcfunction(L, ra_fn_setcolorindex); return 1; }
      break;
   case RA_OBJ_PATTERN:
      if (!strcmp(k, "GetPatternWithTag"))  { lua_pushcfunction(L, ra_fn_pattern_getwithtag); return 1; }
      if (!strcmp(k, "GetPatternsWithTag")) { lua_pushcfunction(L, ra_fn_pattern_getswithtag); return 1; }
      break;
   case RA_OBJ_NOTI:
      if (!strcmp(k, "Notify")) { lua_pushcfunction(L, ra_fn_noti); return 1; }
      break;
   case RA_OBJ_PROFILE:
      if (!strcmp(k, "RenewId")) { lua_pushcfunction(L, ra_fn_noop); return 1; }
      lua_pushnil(L); return 1;                   /* metadata: faked */
   case RA_OBJ_SCRIPTPAD:
      if (!strcmp(k, "Enable")) { lua_pushcfunction(L, ra_fn_noop); return 1; }   /* never enabled */
      break;
   case RA_OBJ_VIDEO:
      if (!strcmp(k, "SceneScale")) { lua_pushnumber(L, 1); return 1; }
      break;
   case RA_OBJ_PAD:
      if (!strcmp(k, "State")) { lua_pushinteger(L, 0); return 1; }
      break;
   }
   return luaL_error(L, "%s: no member '%s'",
                     o->kind == RA_OBJ_FRAME ? "Frame" : o->kind == RA_OBJ_SETTING ? "Setting"
                     : o->kind == RA_OBJ_LIGHT ? "Light" : o->kind == RA_OBJ_BACKDROP ? "Backdrop"
                     : o->kind == RA_OBJ_CAMERA ? "Camera" : o->kind == RA_OBJ_PALETTE ? "Palette"
                     : o->kind == RA_OBJ_LAYERP ? "Layer" : "object", k);
}

static int ra_obj_newindex(lua_State *L)
{
   RaUObj *o = (RaUObj *)luaL_checkudata(L, 1, RA_MT_OBJ);
   Ra3dLua *rt = ra_lua_rt(L);
   Ra3dLuaState *st = &rt->st;
   const char *k = luaL_checkstring(L, 2);
   switch (o->kind)
   {
   case RA_OBJ_SETTING:
      if (!strcmp(k, "EmptyTile")) { st->empty_tile = lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "LocalCam") || !strcmp(k, "TopDownCam")) { st->localcam = lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "SceneRatio") || !strcmp(k, "SmoothTime") || !strcmp(k, "GameSpeed")
          || !strcmp(k, "BgColor") || !strcmp(k, "CustomBgColor") || !strcmp(k, "SamePalette")
          || !strcmp(k, "SameBgPalette") || !strcmp(k, "Shadow"))
         return 0;                                    /* VR scale / matcher extras: ignored */
      break;
   case RA_OBJ_LAYERP:
      if (!strcmp(k, "CastShadow")) { st->layer_cast[o->n] = (uint8_t)lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "RecvShadow")) { st->layer_recv[o->n] = (uint8_t)lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "Offset") || !strcmp(k, "Aligned")) return 0;
      break;
   case RA_OBJ_LIGHT:
      if (!strcmp(k, "Color"))
      {
         RaUCol *c = (RaUCol *)luaL_checkudata(L, 3, RA_MT_COL);
         memcpy(st->light_col, c->v, sizeof(float) * 3); st->light_col_set = 1; return 0;
      }
      if (!strcmp(k, "Direction"))
      {
         if (!ra_lua_tovec(L, 3, st->light_dir)) return luaL_error(L, "Light.Direction: not a vector");
         st->light_dir_set = 1; return 0;
      }
      if (!strcmp(k, "Intensity")) return 0;           /* the user's, as in 3dSen */
      break;
   case RA_OBJ_BACKDROP:
      if (!strcmp(k, "Enable"))     { st->bd_enable = lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "RecvShadow")) { st->bd_recv = lua_toboolean(L, 3); return 0; }
      if (!strcmp(k, "Color"))
      { RaUCol *c = (RaUCol *)luaL_checkudata(L, 3, RA_MT_COL); memcpy(st->bd_color, c->v, sizeof(c->v)); return 0; }
      if (!strncmp(k, "Size", 4) && k[4] >= 'X' && k[4] <= 'Z' && !k[5])
      { st->bd_size[k[4] - 'X'] = (float)luaL_checknumber(L, 3); return 0; }
      if (!strncmp(k, "Ofs", 3) && k[3] >= 'X' && k[3] <= 'Z' && !k[4])
      { st->bd_ofs[k[3] - 'X'] = (float)luaL_checknumber(L, 3); return 0; }
      break;
   case RA_OBJ_CAMERA:
      if (!strcmp(k, "Distance"))
      {
         float d = (float)luaL_checknumber(L, 3);
         if (d < 0) d = 0;
         if (d > 512) d = 512;
         st->cam_set = 1;
         if (d != st->cam_dist) { st->cam_dist = d; st->cam_gen++; }
         return 0;
      }
      if (!strcmp(k, "Mode") || !strcmp(k, "FpvShape")) return 0;
      break;
   case RA_OBJ_PROFILE:
      return 0;                                      /* Maker / Title / GameDev */
   }
   return luaL_error(L, "cannot set '%s'", k);
}

static int ra_obj_eq(lua_State *L)
{
   RaUObj *a = (RaUObj *)luaL_testudata(L, 1, RA_MT_OBJ), *b = (RaUObj *)luaL_testudata(L, 2, RA_MT_OBJ);
   lua_pushboolean(L, a && b && a->kind == b->kind && a->n == b->n);
   return 1;
}

/* ------------------------------------------------------------ the VM */

static void ra_lua_hook(lua_State *L, lua_Debug *ar)
{
   Ra3dLua *rt = ra_lua_rt(L);
   (void)ar;
   rt->left -= 1000;
   if (rt->left < 0) luaL_error(L, "instruction budget exceeded");
}

static void ra_lua_mt(lua_State *L, const char *name, const luaL_Reg *f)
{
   luaL_newmetatable(L, name);
   luaL_setfuncs(L, f, 0);
   lua_pushstring(L, "ra3d");
   lua_setfield(L, -2, "__metatable");
   lua_pop(L, 1);
}

static void ra_lua_class(lua_State *L, const char *global, lua_CFunction call, lua_CFunction index)
{
   lua_newtable(L);
   lua_newtable(L);
   lua_pushcfunction(L, call);  lua_setfield(L, -2, "__call");
   lua_pushcfunction(L, index); lua_setfield(L, -2, "__index");
   lua_setmetatable(L, -2);
   lua_setglobal(L, global);
}

/* pcall with the instruction budget; on error the script dies */
static int ra_lua_call(Ra3dLua *rt, RaLuaScript *s, int nargs, const char *what)
{
   int ok;
   rt->left = rt->budget;
   rt->st.calls++;
   ok = lua_pcall(rt->L, nargs, 0, 0) == LUA_OK;
   if (!ok)
   {
      if (s)
      {
         s->err = 1;
         ra_lua_logf(rt, "3dlua: script '%s' DISABLED in %s — %s", s->name, what,
                     lua_tostring(rt->L, -1) ? lua_tostring(rt->L, -1) : "?");
      }
      lua_pop(rt->L, 1);
   }
   return ok;
}

static void ra_lua_run(Ra3dLua *rt, RaLuaScript *s, int fn, int need_enable, const char *what)
{
   if (s->err || s->fn[fn] == LUA_NOREF || (need_enable && !s->enabled)) return;
   lua_rawgeti(rt->L, LUA_REGISTRYINDEX, s->fn[fn]);
   ra_lua_call(rt, s, 0, what);
}

Ra3dLua *ra3d_lua_new(const Ra3dProfile *prof, ra3d_lua_log_fn logfn, long budget)
{
   Ra3dLua *rt;
   lua_State *L;
   uint32_t i, j;
   static const luaL_Reg vec_f[] = {
      { "__index", ra_vec_index }, { "__newindex", ra_vec_newindex }, { "__add", ra_vec_add },
      { "__sub", ra_vec_sub }, { "__mul", ra_vec_mul }, { "__div", ra_vec_div },
      { "__unm", ra_vec_unm }, { "__eq", ra_vec_eq }, { "__tostring", ra_vec_tostring }, { NULL, NULL } };
   static const luaL_Reg col_f[] = {
      { "__index", ra_col_index }, { "__newindex", ra_col_newindex }, { "__eq", ra_col_eq }, { NULL, NULL } };
   static const luaL_Reg ref_f[] = {
      { "__index", ra_ref_index }, { "__newindex", ra_ref_newindex }, { "__add", ra_vec_add },
      { "__sub", ra_vec_sub }, { "__mul", ra_vec_mul }, { "__unm", ra_vec_unm },
      { "__tostring", ra_vec_tostring }, { NULL, NULL } };
   static const luaL_Reg shape_f[] = {
      { "__index", ra_shape_index }, { "__newindex", ra_shape_newindex }, { NULL, NULL } };
   static const luaL_Reg shape2_f[] = { { "__index", ra_shape2_index }, { NULL, NULL } };
   static const luaL_Reg pshape_f[] = { { "__index", ra_pshape_index }, { "__eq", ra_pshape_eq }, { NULL, NULL } };
   static const luaL_Reg cdata_f[] = { { "__index", ra_cdata_index }, { "__newindex", ra_cdata_newindex }, { NULL, NULL } };
   static const luaL_Reg list_f[] = { { "__index", ra_list_index }, { NULL, NULL } };
   static const luaL_Reg mat_f[] = { { "__index", ra_mat_index }, { "__newindex", ra_mat_newindex }, { NULL, NULL } };
   static const luaL_Reg obj_f[] = {
      { "__index", ra_obj_index }, { "__newindex", ra_obj_newindex }, { "__eq", ra_obj_eq }, { NULL, NULL } };

   if (!prof || !prof->scripts.n) return NULL;
   rt = (Ra3dLua *)calloc(1, sizeof(*rt));
   if (!rt) return NULL;
   rt->prof = prof; rt->logfn = logfn;
   rt->budget = budget > 0 ? budget : 5000000L;
   rt->gen = 1;
   L = luaL_newstate();
   if (!L) { free(rt); return NULL; }
   rt->L = L;
   *(Ra3dLua **)lua_getextraspace(L) = rt;

   /* initial settings: 3dSen's, after _Setting_ */
   rt->st.empty_tile = prof->et_static > 0;
   rt->st.localcam   = prof->lc_static > 0;
   if (prof->clip_set) memcpy(rt->st.clip, prof->clip, sizeof(rt->st.clip));
   else { rt->st.clip[0] = 0.1f; rt->st.clip[1] = 8.1f; rt->st.clip[2] = 8.1f; rt->st.clip[3] = 0.1f; }
   for (i = 0; i < 6; i++) { rt->st.layer_cast[i] = (uint8_t)(i == 2); rt->st.layer_recv[i] = (uint8_t)(i >= 2); }
   rt->st.bd_size[0] = 256; rt->st.bd_size[1] = 240; rt->st.bd_size[2] = 1;   /* Backdrop default */
   rt->st.bd_color[3] = 1; rt->st.bd_recv = 1;
   rt->st.cam_rot[0] = rt->st.cam_rot[1] = 0.81f;                            /* camera reset pose */
   rt->st.cam_dist = (float)RA3D_LUA_CAM_RESET_DIST;

   /* libraries: base, math, table, string; nothing that touches files/OS */
   luaL_requiref(L, "_G", luaopen_base, 1);      lua_pop(L, 1);
   luaL_requiref(L, "math", luaopen_math, 1);    lua_pop(L, 1);
   luaL_requiref(L, "table", luaopen_table, 1);  lua_pop(L, 1);
   luaL_requiref(L, "string", luaopen_string, 1); lua_pop(L, 1);
   {
      static const char *const kill[] = { "dofile", "loadfile", "load", "require",
                                          "collectgarbage", NULL };
      for (i = 0; kill[i]; i++) { lua_pushnil(L); lua_setglobal(L, kill[i]); }
   }
   ra_lua_mt(L, RA_MT_VEC, vec_f);
   ra_lua_mt(L, RA_MT_COL, col_f);
   ra_lua_mt(L, RA_MT_REF, ref_f);
   ra_lua_mt(L, RA_MT_SHAPE, shape_f);
   ra_lua_mt(L, RA_MT_SHAPE2, shape2_f);
   ra_lua_mt(L, RA_MT_PSHAPE, pshape_f);
   ra_lua_mt(L, RA_MT_CDATA, cdata_f);
   ra_lua_mt(L, RA_MT_LIST, list_f);
   ra_lua_mt(L, RA_MT_MAT, mat_f);
   ra_lua_mt(L, RA_MT_OBJ, obj_f);
   ra_lua_class(L, "Vector3", ra_vec_new, ra_vec_class_index);
   ra_lua_class(L, "Vector2", ra_vec_new, ra_vec_class_index);
   ra_lua_class(L, "Color", ra_col_new, ra_col_class_index);
   lua_pushcfunction(L, ra_fn_print); lua_setglobal(L, "print");
   lua_pushcfunction(L, ra_fn_noop);  lua_setglobal(L, "clear");
   {
      static const struct { const char *g; uint32_t kind; } objs[] = {
         { "Frame", RA_OBJ_FRAME }, { "FrameManager", RA_OBJ_FRAME }, { "Setting", RA_OBJ_SETTING },
         { "Light", RA_OBJ_LIGHT }, { "Backdrop", RA_OBJ_BACKDROP }, { "Camera", RA_OBJ_CAMERA },
         { "Script", RA_OBJ_SCRIPT }, { "Palette", RA_OBJ_PALETTE }, { "Pattern", RA_OBJ_PATTERN },
         { "NotiCenter", RA_OBJ_NOTI }, { "Profile", RA_OBJ_PROFILE }, { "ScriptPad", RA_OBJ_SCRIPTPAD },
         { "Video", RA_OBJ_VIDEO }, { "Layer", RA_OBJ_LAYERS }, { "Gamepad", RA_OBJ_PADS },
         { NULL, 0 } };
      for (i = 0; objs[i].g; i++) { ra_lua_push_obj(L, objs[i].kind, 0); lua_setglobal(L, objs[i].g); }
      ra_lua_push_obj(L, RA_OBJ_PAD, 0); lua_setglobal(L, "Gamepad1");
      ra_lua_push_obj(L, RA_OBJ_PAD, 1); lua_setglobal(L, "Gamepad2");
      ra_lua_push_ref(L, RA_REF_CLIP, 0, 0); lua_setglobal(L, "Clipping");
      ra_lua_push_ref(L, RA_REF_ZAPOFS, 0, 0); lua_setglobal(L, "ZapperOffset");
   }
   /* the globals every 3dSen script can rely on: PData[1..64] = 0 and its two helpers */
   (void)luaL_dostring(L,
      "pdata_count = 64\nPData = {}\nfor i = 1, pdata_count do PData[i] = 0 end\n"
      "function GetPData(i) return PData[(i % pdata_count) + 1] end\n"
      "function SetPData(i, value) PData[(i % pdata_count) + 1] = value end\n"
      "function RenewId() end\n"
      /* the read-only `CS.Nes3D.Info` table v2 scripts read (Version "2.0",
       * Title "3dSenVR"). Punch-Out's v2 camera script reads
       * Info.Version to choose Camera.ResetDistance over its v1 fallback. */
      "do local info = setmetatable({}, { __index = { Version = '2.0', Title = '3dSenVR' },\n"
      "  __newindex = function(_, k) error('CS.Nes3D.Info.' .. tostring(k) .. ' is read-only', 2) end,\n"
      "  __metatable = false })\n"
      "CS = { Nes3D = { Info = info } } end\n");
   lua_pushinteger(L, 0); lua_setglobal(L, "frame");
   lua_pushnumber(L, 0);  lua_setglobal(L, "time");
   lua_newtable(L); rt->cache_ref = luaL_ref(L, LUA_REGISTRYINDEX);
   lua_sethook(L, ra_lua_hook, LUA_MASKCOUNT, 1000);

   /* load every script, file order, shared globals (Script.LoadSource) */
   rt->ns = prof->scripts.n;
   rt->sc = (RaLuaScript *)calloc(rt->ns, sizeof(RaLuaScript));
   if (!rt->sc) { ra3d_lua_free(rt); return NULL; }
   for (i = 0; i < rt->ns; i++)
   {
      const Ra3dScript *ps = &prof->scripts.v[i];
      RaLuaScript *s = &rt->sc[i];
      s->name = prof->scriptpool.v + ps->name_off;
      s->tags = ps->tag_len ? prof->scriptpool.v + ps->tag_off : "";
      s->tag_len = ps->tag_len;
      s->enabled = ps->enabled;
      s->star = s->tag_len && memchr(s->tags, '*', s->tag_len) != NULL;
      for (j = 0; j < RA_LUA_NFN; j++) s->fn[j] = LUA_NOREF;
      for (j = 0; j < RA_LUA_NFN; j++) { lua_pushnil(L); lua_setglobal(L, RA_LUA_FNAMES[j]); }
      if (!ps->src_len) continue;
      if (luaL_loadbuffer(L, prof->scriptpool.v + ps->src_off, ps->src_len, s->name) != LUA_OK)
      {
         s->err = 1;
         ra_lua_logf(rt, "3dlua: script '%s' DISABLED at load — %s", s->name, lua_tostring(L, -1));
         lua_pop(L, 1);
         continue;
      }
      if (!ra_lua_call(rt, s, 0, "chunk")) continue;
      for (j = 0; j < RA_LUA_NFN; j++)
      {
         if (lua_getglobal(L, RA_LUA_FNAMES[j]) == LUA_TFUNCTION)
            s->fn[j] = luaL_ref(L, LUA_REGISTRYINDEX);
         else lua_pop(L, 1);
      }
   }

   /* Pattern3D.LinkToScript for every profile Pattern3D */
   rt->lwords = (rt->ns + 63) / 64;
   rt->links = (uint64_t *)calloc((size_t)prof->shapes.n * rt->lwords + 1, sizeof(uint64_t));
   if (!rt->links) { ra3d_lua_free(rt); return NULL; }
   for (i = 0; i < prof->shapes.n; i++)
   {
      const Ra3dShape3D *sh = &prof->shapes.v[i];
      for (j = 0; j < rt->ns; j++)
      {
         RaLuaScript *s = &rt->sc[j];
         int link = s->star;
         if (!link && sh->tag_len)
         {  /* any of the script's trimmed tags is one of the shape's */
            const char *t = s->tags; size_t n = s->tag_len, a = 0;
            while (a <= n && !link)
            {
               size_t b = a, e;
               while (b < n && t[b] != ',') b++;
               e = b;
               while (a < e && (t[a] == ' ' || t[a] == '\t')) a++;
               while (e > a && (t[e-1] == ' ' || t[e-1] == '\t')) e--;
               if (e > a && ra_lua_tags_has(prof->tagpool.v + sh->tag_off, sh->tag_len, t + a, e - a))
                  link = 1;
               a = b + 1;
            }
         }
         if (link) rt->links[(size_t)i * rt->lwords + j / 64] |= 1ull << (j % 64);
      }
   }

   /* Start, every script (RunStart checks error, not enable) */
   for (i = 0; i < rt->ns; i++) ra_lua_run(rt, &rt->sc[i], RA_FN_START, 0, "Start");
   rt->st.scripts = rt->ns;
   for (i = 0, j = 0; i < rt->ns; i++) if (!rt->sc[i].err) j++;
   rt->st.alive = j;
   ra_lua_logf(rt, "3dlua: VM up — Lua 5.3.6, %u scripts, %u alive after Start, budget %ld instr/call",
               rt->ns, j, rt->budget);
   return rt;
}

void ra3d_lua_free(Ra3dLua *rt)
{
   uint32_t i;
   if (!rt) return;
   if (rt->L && rt->sc)
   {
      rt->gen++; rt->nli = rt->nscr = 0;
      for (i = 0; i < rt->ns; i++) ra_lua_run(rt, &rt->sc[i], RA_FN_END, 0, "End");
   }
   if (rt->L) lua_close(rt->L);
   free(rt->sc); free(rt->links); free(rt->li); free(rt->rg); free(rt->scr);
   free(rt->lists); free(rt->var_x); free(rt->var_g); free(rt->st.xatlas);
   free(rt);
}

const Ra3dLuaState *ra3d_lua_state(const Ra3dLua *rt) { return rt ? &rt->st : NULL; }
void ra3d_lua_reset_peak(Ra3dLua *rt) { if (rt) rt->st.ms_peak = 0.0; }

int ra3d_lua_eval(Ra3dLua *rt, const char *code)
{
   if (!rt || !rt->L || !code) return 0;
   if (luaL_loadstring(rt->L, code) != LUA_OK)
   { ra_lua_logf(rt, "3dlua: eval: %s", lua_tostring(rt->L, -1)); lua_pop(rt->L, 1); return 0; }
   if (!ra_lua_call(rt, NULL, 0, "eval")) return 0;
   return 1;
}

/* shadow participation, with the scripts' layer table and the
 * per-shape CastShadow/RecvShadow/renderStyle/alpha, as 3dSen decides it. */
static uint32_t ra_lua_shadow_flags(const Ra3dLuaState *st, int layer, int cast, int recv,
                                    int style, float alpha)
{
   uint32_t f = 0;
   int rl = (layer == 0 || layer > 5) ? 2 : layer;
   int lc = st->layer_cast[rl] && cast, lr = st->layer_recv[rl] && recv;
   if (rl == 1) { lc = 0; lr = 0; }
   if (style != 2 && alpha < 1.0f) lc = 0;
   if (style <= 0) { f |= RA3D_INST_HIDDEN; lc = 0; }
   if (style == 2) { f |= RA3D_INST_SHADOWONLY; lc = 1; }
   if (!lc) f |= RA3D_INST_NOCAST;
   if (!lr) f |= RA3D_INST_NORECV;
   return f;
}

#define RA_LUA_SHADOW_BITS (RA3D_INST_NOCAST | RA3D_INST_NORECV | RA3D_INST_SHADOWONLY \
                            | RA3D_INST_HIDDEN | RA3D_INST_UI)

static int ra_lua_push_instance(Ra3dGeoFrame *g, const Ra3dGeoInstance *in)
{
   if (!ra3d_grow((void **)&g->instances, &g->instance_cap, g->instance_count + 1, sizeof(Ra3dGeoInstance)) ||
       !ra3d_grow((void **)&g->shape_of, &g->shape_of_cap, g->instance_count + 1, sizeof(uint32_t)) ||
       !ra3d_grow((void **)&g->region_of, &g->region_of_cap, g->instance_count + 1, sizeof(uint32_t)))
      return 0;
   g->shape_of[g->instance_count] = RA3D_NO_SHAPE;
   g->region_of[g->instance_count] = RA3D_NO_SHAPE;
   g->instances[g->instance_count++] = *in;
   return 1;
}

int ra3d_lua_frame(Ra3dLua *rt, const Ra3dScene *scene, const uint8_t *ram,
                   const Ra3dKnobs *k, Ra3dGeoFrame *g)
{
   lua_State *L;
   const Ra3dProfile *p;
   uint32_t i, j, n0, total;
   double t0 = ra3d_now_ms();
   int flat;

   if (!rt || !rt->L || !scene || !g || !k) return 0;
   L = rt->L; p = rt->prof;
   rt->gen++;
   if (rt->gen == 0) rt->gen = 1;
   rt->scene = scene; rt->ram = ram; rt->k = k; rt->g = g;
   rt->st.xatlas_n = 0; rt->st.inserted = 0;
   memset(&RA_LUA_DEAD, 0, sizeof(RA_LUA_DEAD));   /* stale writes never outlive a frame */
   RA_LUA_DEAD.region = 0xFFFFFFFFu; RA_LUA_DEAD.shape = 0xFFFFFFFFu;

   /* Converter: 16 palettes, colour 0 of each = backdrop, rest = RAM i % 32 */
   for (i = 0; i < 64; i++)
      rt->st.pal_idx[i] = scene->PaletteRam ? (uint8_t)(scene->PaletteRam[(i & 3) ? (i & 31) : 0] & 63) : 0;

   /* this frame's Pattern3D copies (Pattern.AssignFrom) */
   n0 = g->instance_count;
   if (!ra_lua_grow((void **)&rt->li, &rt->cap_li, n0 + 1, sizeof(RaLuaInst)) ||
       !ra_lua_grow((void **)&rt->scr, &rt->cap_scr, n0 + 1, sizeof(uint32_t)) ||
       !ra_lua_grow((void **)&rt->rg, &rt->cap_rg, g->region_count + 1, sizeof(Ra3dGeoRegion)))
      return 0;
   memcpy(rt->rg, g->regions, (size_t)g->region_count * sizeof(Ra3dGeoRegion));
   rt->nrg = g->region_count;
   rt->nli = rt->nscr = 0;
   for (i = 0; i < n0; i++)
   {
      uint32_t s = g->shape_of[i];
      const Ra3dShape3D *sh;
      RaLuaInst *in;
      if (s == RA3D_NO_SHAPE || s >= p->shapes.n) continue;
      sh = &p->shapes.v[s];
      in = &rt->li[rt->nli];
      memcpy(in->off, sh->offset, sizeof(in->off));
      memcpy(in->rot, sh->rot,    sizeof(in->rot));
      memcpy(in->scl, sh->scale,  sizeof(in->scl));
      memcpy(in->piv, sh->pivot,  sizeof(in->piv));
      in->alpha = sh->alpha;
      in->style = sh->render_style;
      in->custom_pal = -1;
      in->layer = sh->layer;
      in->cast = !sh->tag_nocast; in->recv = !sh->tag_norecv;
      in->scriptable = 1;
      in->inst = i; in->shape = s;
      in->region = g->region_of[i];
      in->ins_pal = -1;
      rt->scr[rt->nscr++] = rt->nli++;
   }
   rt->st.scriptable = rt->nscr;

   lua_newtable(L);
   lua_rawseti(L, LUA_REGISTRYINDEX, rt->cache_ref);
   lua_pushinteger(L, (lua_Integer)scene->FrameNumber); lua_setglobal(L, "frame");
   lua_pushnumber(L, (lua_Number)scene->FrameNumber / 60.0); lua_setglobal(L, "time");

   /* every script's Update, in file order */
   for (j = 0; j < rt->ns; j++) ra_lua_run(rt, &rt->sc[j], RA_FN_UPDATE, 1, "Update");

   total = 0;
   for (j = 0; j < rt->ns; j++)
   {
      RaLuaScript *s = &rt->sc[j];
      s->list_n = 0;
      if (s->err || !s->enabled || s->fn[RA_FN_UPDATES] == LUA_NOREF) continue;
      for (i = 0; i < rt->nscr; i++)
         if (rt->links[(size_t)rt->li[rt->scr[i]].shape * rt->lwords + j / 64] & (1ull << (j % 64)))
            s->list_n++;
      s->list_first = total;
      total += s->list_n;
   }
   if (total && !ra_lua_grow((void **)&rt->lists, &rt->cap_lists, total, sizeof(uint32_t))) return 0;
   for (j = 0; j < rt->ns; j++)
   {
      RaLuaScript *s = &rt->sc[j];
      uint32_t w = 0;
      if (!s->list_n) continue;
      for (i = 0; i < rt->nscr; i++)
         if (rt->links[(size_t)rt->li[rt->scr[i]].shape * rt->lwords + j / 64] & (1ull << (j % 64)))
            rt->lists[s->list_first + w++] = rt->scr[i];
   }
   for (j = 0; j < rt->ns; j++)
   {
      RaLuaScript *s = &rt->sc[j];
      for (i = 0; i < s->list_n && !s->err; i++)
      {
         RaUShape *u;
         uint32_t li = rt->lists[s->list_first + i];
         ra_lua_push_shape(L, li);
         lua_setglobal(L, "shape");
         u = (RaUShape *)lua_newuserdata(L, sizeof(*u));
         u->gen = rt->gen; u->li = li;
         luaL_setmetatable(L, RA_MT_SHAPE2);
         lua_setglobal(L, "shape2D");
         lua_rawgeti(L, LUA_REGISTRYINDEX, s->fn[RA_FN_UPDATES]);
         ra_lua_call(rt, s, 0, "UpdateS");
      }
   }
   for (j = 0; j < rt->ns; j++) ra_lua_run(rt, &rt->sc[j], RA_FN_LATE, 1, "LateUpdate");

   /* ---- write back (the renderer reads the copies) ---- */
   {
      int lcp = k->lua_active ? (k->lua_localcam != 0) : (ra3d_profile_localcam(p, NULL, NULL) & 1);
      int lca = k->localcam_active < 0 ? lcp : k->localcam_active;
      flat = k->flat_shapes >= 0 ? k->flat_shapes : (lcp && !lca);
   }
   for (i = 0; i < n0; i++)
   {  /* everything not scripted still answers to the scripts' layer table */
      Ra3dGeoInstance *in = &g->instances[i];
      if (g->shape_of[i] != RA3D_NO_SHAPE && g->shape_of[i] < p->shapes.n) continue;
      in->flags = (in->flags & ~RA_LUA_SHADOW_BITS)
                | ra_lua_shadow_flags(&rt->st, in->zlayer, 1, 1, 1, in->alpha);
   }
   if (!rt->var_g || rt->cap_var_x < p->vars.n)
   {
      free(rt->var_x); free(rt->var_g);
      rt->var_x = (int32_t *)calloc(p->vars.n + 1, sizeof(int32_t));
      rt->var_g = (uint32_t *)calloc(p->vars.n + 1, sizeof(uint32_t));
      rt->cap_var_x = p->vars.n + 1;
      if (!rt->var_x || !rt->var_g) { rt->cap_var_x = 0; return 0; }
   }
   rt->var_gen++;
   for (i = 0; i < rt->nli; i++)
   {
      RaLuaInst *li = &rt->li[i];
      const Ra3dShape3D *sh = &p->shapes.v[li->shape];
      const Ra3dGeoRegion *rg = li->region < rt->nrg ? &rt->rg[li->region] : NULL;
      Ra3dGeoInstance tmp, *in;
      if (li->inst == 0xFFFFFFFFu)
      {  /* Stage 1b: an inserted shape — cells from the profile's CHR */
         const Ra3dPattern *pa = &p->patterns.v[sh->pattern];
         uint32_t ncell = (uint32_t)pa->w * pa->h, base, c;
         float d = sh->size_z * k->size_z_scale;
         int tex_direct = 0;
         if (!ncell || ncell > 4096) continue;
         if (!ra3d_grow((void **)&g->cells, &g->cell_cap, g->cell_count + ncell, sizeof(Ra3dGeoCell)))
            return 0;
         base = g->cell_count;
         for (c = 0; c < ncell; c++)
         {
            Ra3dGeoCell z;
            z.gx = (uint8_t)(c % pa->w); z.gy = (uint8_t)(c / pa->w);
            z.pal = 0; z.flip = 0; z.chr = RA3D_CELL_EMPTY; z.pad = 0;
            g->cells[base + c] = z;
         }
         /* a textured Pattern3D is laid from its texture.
          * only on the authored (non-wildcard) cells — those
          * are the tiles Frame.AddNewShape lays, and 3dSen draws per
          * tile — and a Direct texture is read per cell. */
         if (sh->tt_gw && sh->tt_gw == pa->w && sh->tt_gh == pa->h)
         {
            int direct = sh->dtex_w && sh->dtex_w == (uint32_t)pa->w * 8u && sh->dtex_h == (uint32_t)pa->h * 8u;
            {
               for (c = 0; c < pa->cell_count; c++)
               {
                  const Ra3dPatCell *cl = &p->cells.v[pa->cell_first + c];
                  uint32_t ci, xi;
                  if (cl->gx >= pa->w || cl->gy >= pa->h) continue;
                  ci = (uint32_t)cl->gy * pa->w + cl->gx;
                  xi = ra3d_frame_tt_tile(g, p, li->shape, ci);
                  if (xi == 0xFFFFFFFFu || scene->AtlasCount + xi >= RA3D_CELL_EMPTY) continue;
                  g->cells[base + ci].chr = (uint16_t)(scene->AtlasCount + xi);
                  g->cells[base + ci].pal = (uint8_t)ra_lua_ins_group(li->ins_pal);
                  g->cells[base + ci].pad = direct ? (uint16_t)(ci + 1u) : 0u;
               }
               if (direct) { tex_direct = 1; }
            }
         }
         else
         for (c = 0; c < pa->cell_count; c++)
         {
            const Ra3dPatCell *cl = &p->cells.v[pa->cell_first + c];
            uint32_t v = p->cellvars.v[cl->var_first];
            const Ra3dVariant *vr = &p->vars.v[v];
            Ra3dGeoCell *z;
            uint32_t ax;
            if (cl->gx >= pa->w || cl->gy >= pa->h) continue;
            if (rt->var_g[v] != rt->var_gen)
            {
               rt->var_g[v] = rt->var_gen;
               rt->var_x[v] = (int32_t)ra_lua_xatlas_add(rt, vr->chr);
            }
            ax = (uint32_t)rt->var_x[v];
            if (ax == 0xFFFFFFFFu) continue;
            z = &g->cells[base + (uint32_t)cl->gy * pa->w + cl->gx];
            z->chr = (uint16_t)(scene->AtlasCount + ax);
            z->flip = (uint8_t)((vr->fx ? 1 : 0) | (vr->fy ? 2 : 0));
            z->pal = (uint8_t)ra_lua_ins_group(li->ins_pal);
         }
         g->cell_count = base + ncell;
         memset(&tmp, 0, sizeof(tmp));
         tmp.pos[0] = 0; tmp.pos[1] = 0;
         tmp.size[0] = (float)(pa->w * 8); tmp.size[1] = (float)(pa->h * 8);
         tmp.size[2] = d == 0.0f ? 1.0f : d;
         tmp.cell_offset = base; tmp.cell_count = (uint16_t)ncell;
         tmp.geo = sh->geo; tmp.pattern = (int32_t)pa->id;
         if (tex_direct)
         { tmp.dtex = sh->dtex_first + 1u; tmp.dtex_gw = pa->w; }   /* per cell */
         tmp.flags = RA3D_INST_SPRITE | RA3D_INST_INSERTED | (uint32_t)sh->fill_flags
                   | ((uint32_t)sh->empty_color << RA3D_INST_EMPTY_SHIFT)
                   | ra3d_mode_flags(sh, k);
         if (!ra_lua_push_instance(g, &tmp)) return 0;
         li->inst = g->instance_count - 1;
      }
      in = &g->instances[li->inst];
      in->pos[2] = ra3d_layer_centre_z(p, k, li->layer < 6 ? li->layer : 2, in->size[2]);
      /* `flat_shapes` stands up only the profile's AUTHORED
       * rotations. A rotation a live script wrote this frame is the scene's
       * own layout (Duck Hunt's Scene1 lays the HUD flat and enables raised
       * text variants that only make sense on a floor); standing it upright
       * put those variants' faces on the box's plane and they z-fought. */
      ra3d_inst_xform(in, rg, li->scl, li->rot, li->off, li->piv, k->unity_frame,
                      flat && li->rot[0] == sh->rot[0] && li->rot[1] == sh->rot[1]
                           && li->rot[2] == sh->rot[2]);
      in->alpha = li->alpha;
      in->zlayer = li->layer;
      in->pal_override = li->custom_pal >= 0 ? (uint32_t)(li->custom_pal & 15) + 1u : 0u;
      in->flags &= ~(RA_LUA_SHADOW_BITS | RA3D_INST_ROT_XYZ | RA3D_INST_ROT_YXZ);
      if (k->unity_frame) in->flags |= sh->tag_gaxis ? RA3D_INST_ROT_YXZ : RA3D_INST_ROT_XYZ;
      in->flags |= ra_lua_shadow_flags(&rt->st, li->layer, li->cast, li->recv, li->style, li->alpha);
      if (li->layer == 1) in->flags |= RA3D_INST_UI;
   }

   /* the Backdrop: one lit box (position = Offset, scale = Size,
    * a unit cube about the screen centre) */
   if (rt->st.bd_enable && rt->st.bd_size[0] > 0 && rt->st.bd_size[1] > 0)
   {
      static const uint8_t solid[16] = { 0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF, 0,0,0,0,0,0,0,0 };
      uint32_t ax = ra_lua_xatlas_add(rt, solid);
      if (ax != 0xFFFFFFFFu &&
          ra3d_grow((void **)&g->cells, &g->cell_cap, g->cell_count + 1, sizeof(Ra3dGeoCell)))
      {
         Ra3dGeoInstance bd;
         Ra3dGeoCell *z = &g->cells[g->cell_count];
         float sx = rt->st.bd_size[0], sy = rt->st.bd_size[1], szz = rt->st.bd_size[2];
         float cx = 128.0f + rt->st.bd_ofs[0];
         /* the screen centre is (128, 120) in 3dSen's frame: NES y = RA3D_UNITY_H - 120 - ofs.y */
         float cy = (float)(RA3D_UNITY_H - 120) - rt->st.bd_ofs[1];
         z->gx = 0; z->gy = 0; z->pal = 16; z->flip = 0;
         z->chr = (uint16_t)(scene->AtlasCount + ax); z->pad = 0;
         memset(&bd, 0, sizeof(bd));
         bd.pos[0] = cx - sx * 0.5f; bd.pos[1] = cy - sy * 0.5f;
         bd.pos[2] = -rt->st.bd_ofs[2];                 /* 3dSen +Z into the screen */
         bd.size[0] = 8; bd.size[1] = 8; bd.size[2] = szz > 0.01f ? szz : 0.01f;
         bd.scale[0] = sx / 8.0f; bd.scale[1] = sy / 8.0f; bd.scale[2] = 1.0f;
         bd.pivot[0] = 0; bd.pivot[1] = 0; bd.pivot[2] = 0.5f;
         bd.alpha = 1.0f; bd.zlayer = 2; bd.pattern = -1;
         bd.cell_offset = g->cell_count; bd.cell_count = 1;
         bd.flags = RA3D_INST_INSERTED | RA3D_INST_NOCAST | (rt->st.bd_recv ? 0u : RA3D_INST_NORECV)
                  | (4u << RA3D_INST_EMPTY_SHIFT);
         g->cell_count++;
         if (!ra_lua_push_instance(g, &bd)) return 0;
      }
   }

   for (i = 0, j = 0; i < rt->ns; i++) if (!rt->sc[i].err) j++;
   rt->st.alive = j;
   rt->st.ms = ra3d_now_ms() - t0;
   if (rt->st.ms > rt->st.ms_peak) rt->st.ms_peak = rt->st.ms;
   return 1;
}

/* ---- Lua 5.3.6 itself, as one unity build, LAST ---- */
#if defined(__clang__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wstring-plus-int"
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#pragma clang diagnostic ignored "-Wcomma"
#pragma clang diagnostic ignored "-Wconversion"
#pragma clang diagnostic ignored "-Wunused-parameter"
#pragma clang diagnostic ignored "-Wsign-compare"
#pragma clang diagnostic ignored "-Wimplicit-fallthrough"
#pragma clang diagnostic ignored "-Wmissing-prototypes"
#endif
#include "../../vendor/RetroArch/deps/lua/src/lapi.c"
#include "../../vendor/RetroArch/deps/lua/src/lcode.c"
#include "../../vendor/RetroArch/deps/lua/src/lctype.c"
#include "../../vendor/RetroArch/deps/lua/src/ldebug.c"
#include "../../vendor/RetroArch/deps/lua/src/ldo.c"
#include "../../vendor/RetroArch/deps/lua/src/ldump.c"
#include "../../vendor/RetroArch/deps/lua/src/lfunc.c"
#include "../../vendor/RetroArch/deps/lua/src/lgc.c"
#include "../../vendor/RetroArch/deps/lua/src/llex.c"
#include "../../vendor/RetroArch/deps/lua/src/lmem.c"
#include "../../vendor/RetroArch/deps/lua/src/lobject.c"
#include "../../vendor/RetroArch/deps/lua/src/lopcodes.c"
#include "../../vendor/RetroArch/deps/lua/src/lparser.c"
#include "../../vendor/RetroArch/deps/lua/src/lstate.c"
#include "../../vendor/RetroArch/deps/lua/src/lstring.c"
#include "../../vendor/RetroArch/deps/lua/src/ltable.c"
#include "../../vendor/RetroArch/deps/lua/src/ltm.c"
#include "../../vendor/RetroArch/deps/lua/src/lundump.c"
#include "../../vendor/RetroArch/deps/lua/src/lvm.c"
#include "../../vendor/RetroArch/deps/lua/src/lzio.c"
#define panic ra3d_lua_panic   /* RetroArch declares a global panic() */
#include "../../vendor/RetroArch/deps/lua/src/lauxlib.c"
#undef panic
#include "../../vendor/RetroArch/deps/lua/src/lbaselib.c"
#include "../../vendor/RetroArch/deps/lua/src/lmathlib.c"
#include "../../vendor/RetroArch/deps/lua/src/lstrlib.c"
#include "../../vendor/RetroArch/deps/lua/src/ltablib.c"
#if defined(__clang__)
#pragma clang diagnostic pop
#endif

#endif /* RA3D_LUA_IMPLEMENTATION */
