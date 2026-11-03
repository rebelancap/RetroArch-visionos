/* ra3d_match.h — which 3dSen profile belongs to the loaded ROM
 *
 * 3dSen itself never identifies a ROM: its library is profile-first (the user
 * picks a game, then points it at a ROM file), a `.3dn` carries no ROM hash
 * (its metadata is Type/Id/Title/Maker/GameDev/Des), and 3dSen's ROM CRC
 * only guards savestates. So there is no 3dSen recipe to
 * mirror; we match by CONTENT, with 3dSen's own tile key:
 *
 *   - a profile's signature is the set of distinct raw 16-byte CHR tiles in
 *     its Pattern2D grids (the matcher's own identity), minus
 *     solid tiles (all 16 bytes equal: blank / solid fills every game has);
 *   - the ROM's tile pool is every 16-byte CHR-ROM tile (16-byte steps) plus
 *     every 16-byte window of PRG-ROM at EVERY byte offset (CHR-RAM games keep
 *     their tiles in PRG, usually uncompressed, not necessarily aligned);
 *   - coverage = |signature ∩ pool| / |signature|.
 *
 * A profile is eligible at coverage >= min_cov (0.30) with >= 32 tiles found
 * and a signature of >= 16 tiles. The winner is the best coverage; among
 * profiles within 0.05 of it, the one with the MOST tiles found (a profile
 * whose tiles are a subset of another game's — Lolo 2 in Lolo 3, Tetris
 * Nintendo in Tetris Famicom — must not take the bigger game), then name order.
 *
 * The bundled profiles' signatures are precomputed at build time into
 * `3dsen-profiles/index.bin` (scripts/ra3d-profile-index.c, same parser and
 * same hash as here); user `.3dn` files are signed at run time.
 *
 * Tile hash: h(lo, hi) = mix64(lo ^ mix64(hi + K)), lo/hi = CHR bytes 0-7 /
 * 8-15 little-endian, mix64 = splitmix64's finaliser, K = 0x9E3779B97F4A7C15.
 *
 * Also computed for the beacon (identification, not matching):
 *   crc_nointro — CRC-32 of the ROM minus its iNES header and trainer
 *                 (No-Intro / libretro-database convention);
 *   crc_3dsen   — the CRC 3dSen keys savestates by: CRC-32 over CHR then PRG,
 *                 header stripped, trainer NOT skipped, and a CHR-RAM cart
 *                 counts as 32 KB of zeros.
 *
 * Header-only: define RA3D_MATCH_IMPLEMENTATION in ONE translation unit that
 * has already included ra3d_shape.h with RA3D_SHAPE_IMPLEMENTATION (the
 * profile signer reads Ra3dProfile's interned variants).
 */
#ifndef RA3D_MATCH_H
#define RA3D_MATCH_H

#include <stdint.h>
#include <stddef.h>

#define RA3D_MATCH_INDEX_MAGIC  "RA3DIDX1"
#define RA3D_MATCH_MIN_COV      0.30
#define RA3D_MATCH_MIN_FOUND    32u
#define RA3D_MATCH_MIN_SIG      16u
#define RA3D_MATCH_NEAR         0.05
/* NES ROMs are <= 2 MB; anything bigger is not one (and its tile set would be a
 * large transient allocation), so the shell does not read it */
#define RA3D_MATCH_MAX_ROM      (4 * 1024 * 1024)

typedef struct
{
   char      name[128];       /* file name, e.g. "punchout.3dn"        */
   char      id[32];          /* profile Id (.3dn field 7), "" if none */
   uint32_t  ntiles;
   uint64_t *tiles;           /* sorted, distinct tile hashes           */
} Ra3dMatchEntry;

typedef struct
{
   uint32_t        n;
   Ra3dMatchEntry *e;
} Ra3dMatchIndex;

/* A ROM's tile pool plus its identification CRCs. */
typedef struct
{
   uint64_t *slots;           /* open-addressed set, 0 = empty           */
   uint32_t  mask;
   uint32_t  count;           /* distinct non-solid tiles                */
   uint32_t  prg, chr;        /* bytes (as present in the file)          */
   int       ines;            /* 1 iNES / NES 2.0 header, 0 headerless   */
   uint32_t  crc_nointro, crc_3dsen;
} Ra3dRomTiles;

/* One candidate's score. */
typedef struct
{
   uint32_t found, ntiles;
   double   cov;
} Ra3dMatchScore;

uint64_t ra3d_match_tile_hash(const uint8_t chr[16]);
int      ra3d_match_tile_solid(const uint8_t chr[16]);

/* index.bin: magic, u32 n, then per entry u16 namelen + name, u16 idlen + id,
 * u32 ntiles + ntiles x u64 (all little-endian). */
Ra3dMatchIndex *ra3d_match_index_load(const void *data, size_t len,
                                      char *err, size_t errlen);
void            ra3d_match_index_free(Ra3dMatchIndex *ix);

/* The `.3dn` profile Id (top-level field 7) into out ("" if absent). */
void ra3d_match_profile_id(const void *data, size_t len, char *out, size_t cap);

int  ra3d_match_rom_scan(const uint8_t *rom, size_t len, Ra3dRomTiles *out);
void ra3d_match_rom_free(Ra3dRomTiles *rt);
void ra3d_match_score(const Ra3dRomTiles *rt, const uint64_t *tiles,
                      uint32_t ntiles, Ra3dMatchScore *out);
/* 1 if the score makes the profile eligible at min_cov. */
int  ra3d_match_eligible(const Ra3dMatchScore *s, double min_cov);
/* 1 if a beats b under the winner rule above (names break exact ties). */
int  ra3d_match_better(const Ra3dMatchScore *a, const char *an,
                       const Ra3dMatchScore *b, const char *bn);

#ifdef RA3D_SHAPE_IMPLEMENTATION
/* A parsed profile's signature: sorted distinct hashes, malloc'd. */
int  ra3d_match_profile_tiles(const Ra3dProfile *p, uint64_t **out, uint32_t *n);
#endif

#endif /* RA3D_MATCH_H */

/* ===================================================================== */
#ifdef RA3D_MATCH_IMPLEMENTATION
#ifndef RA3D_MATCH_IMPLEMENTED
#define RA3D_MATCH_IMPLEMENTED

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static uint64_t ra3d_match_mix64(uint64_t z)
{
   z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ULL;
   z = (z ^ (z >> 27)) * 0x94D049BB133111EBULL;
   return z ^ (z >> 31);
}

static uint64_t ra3d_match_le64(const uint8_t *p)
{
   uint64_t v = 0; int i;
   for (i = 7; i >= 0; i--) v = (v << 8) | p[i];
   return v;
}

uint64_t ra3d_match_tile_hash(const uint8_t chr[16])
{
   uint64_t lo = ra3d_match_le64(chr), hi = ra3d_match_le64(chr + 8);
   uint64_t h  = ra3d_match_mix64(lo ^ ra3d_match_mix64(hi + 0x9E3779B97F4A7C15ULL));
   return h ? h : 1;   /* 0 marks an empty slot */
}

int ra3d_match_tile_solid(const uint8_t chr[16])
{
   int i;
   for (i = 1; i < 16; i++) if (chr[i] != chr[0]) return 0;
   return 1;
}

static int ra3d_match_u64_cmp(const void *a, const void *b)
{
   uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
   return (x > y) - (x < y);
}

static uint32_t ra3d_match_sort_unique(uint64_t *v, uint32_t n)
{
   uint32_t i, w;
   if (!n) return 0;
   qsort(v, n, sizeof(uint64_t), ra3d_match_u64_cmp);
   for (i = 1, w = 1; i < n; i++) if (v[i] != v[w - 1]) v[w++] = v[i];
   return w;
}

/* ------------------------------------------------------------ index file */

static int ra3d_match_rd(const uint8_t **p, const uint8_t *end, void *dst, size_t n)
{
   if ((size_t)(end - *p) < n) return 0;
   memcpy(dst, *p, n); *p += n; return 1;
}

void ra3d_match_index_free(Ra3dMatchIndex *ix)
{
   uint32_t i;
   if (!ix) return;
   for (i = 0; i < ix->n; i++) free(ix->e[i].tiles);
   free(ix->e);
   free(ix);
}

Ra3dMatchIndex *ra3d_match_index_load(const void *data, size_t len,
                                      char *err, size_t errlen)
{
   const uint8_t *p = (const uint8_t *)data, *end = p + len;
   Ra3dMatchIndex *ix;
   uint32_t n, i;
   uint8_t b4[4], b2[2];
   if (len < 12 || memcmp(p, RA3D_MATCH_INDEX_MAGIC, 8))
   { if (err) snprintf(err, errlen, "bad magic"); return NULL; }
   p += 8;
   ra3d_match_rd(&p, end, b4, 4);
   n = (uint32_t)b4[0] | (uint32_t)b4[1] << 8 | (uint32_t)b4[2] << 16 | (uint32_t)b4[3] << 24;
   if (n > 100000) { if (err) snprintf(err, errlen, "absurd count %u", n); return NULL; }
   ix = (Ra3dMatchIndex *)calloc(1, sizeof(*ix));
   if (!ix) return NULL;
   ix->e = (Ra3dMatchEntry *)calloc(n ? n : 1, sizeof(Ra3dMatchEntry));
   if (!ix->e) { free(ix); return NULL; }
   for (i = 0; i < n; i++)
   {
      Ra3dMatchEntry *e = &ix->e[i];
      uint16_t sl; uint32_t nt, j;
      ix->n = i;   /* entries [0, i) are complete if we bail */
      if (!ra3d_match_rd(&p, end, b2, 2)) goto trunc;
      sl = (uint16_t)(b2[0] | b2[1] << 8);
      if (sl >= sizeof(e->name) || !ra3d_match_rd(&p, end, e->name, sl)) goto trunc;
      e->name[sl] = 0;
      if (!ra3d_match_rd(&p, end, b2, 2)) goto trunc;
      sl = (uint16_t)(b2[0] | b2[1] << 8);
      if (sl >= sizeof(e->id) || !ra3d_match_rd(&p, end, e->id, sl)) goto trunc;
      e->id[sl] = 0;
      if (!ra3d_match_rd(&p, end, b4, 4)) goto trunc;
      nt = (uint32_t)b4[0] | (uint32_t)b4[1] << 8 | (uint32_t)b4[2] << 16 | (uint32_t)b4[3] << 24;
      if ((size_t)(end - p) / 8 < nt) goto trunc;
      e->tiles = (uint64_t *)malloc((size_t)(nt ? nt : 1) * sizeof(uint64_t));
      if (!e->tiles) goto trunc;
      for (j = 0; j < nt; j++, p += 8) e->tiles[j] = ra3d_match_le64(p);
      e->ntiles = nt;
   }
   ix->n = n;
   return ix;
trunc:
   if (err) snprintf(err, errlen, "truncated at entry %u", i);
   ix->n = i + 1;          /* free the partial entry's tiles too */
   ra3d_match_index_free(ix);
   return NULL;
}

/* ------------------------------------------------------------ profile id */

static int ra3d_match_varint(const uint8_t **p, const uint8_t *end, uint64_t *v)
{
   uint64_t r = 0; int s = 0;
   while (*p < end && s < 64)
   {
      uint8_t b = *(*p)++;
      r |= (uint64_t)(b & 0x7F) << s;
      if (!(b & 0x80)) { *v = r; return 1; }
      s += 7;
   }
   return 0;
}

void ra3d_match_profile_id(const void *data, size_t len, char *out, size_t cap)
{
   const uint8_t *p = (const uint8_t *)data, *end = p + len;
   if (cap) out[0] = 0;
   while (p < end)
   {
      uint64_t key, v;
      if (!ra3d_match_varint(&p, end, &key)) return;
      switch (key & 7)
      {
      case 0: if (!ra3d_match_varint(&p, end, &v)) return; break;
      case 1: if (end - p < 8) return; p += 8; break;
      case 5: if (end - p < 4) return; p += 4; break;
      case 2:
         if (!ra3d_match_varint(&p, end, &v) || (uint64_t)(end - p) < v) return;
         if ((key >> 3) == 7 && cap)
         {
            size_t n = v < cap - 1 ? (size_t)v : cap - 1;
            memcpy(out, p, n); out[n] = 0;
            return;
         }
         p += v;
         break;
      default: return;   /* groups only occur inside messages we skip whole */
      }
   }
}

/* ------------------------------------------------------------ the ROM */

static uint32_t ra3d_match_crc_tab[256];
static int      ra3d_match_crc_ready = 0;

static uint32_t ra3d_match_crc(uint32_t crc, const uint8_t *d, size_t n)
{
   size_t i;
   if (!ra3d_match_crc_ready)
   {
      uint32_t k, c; int b;
      for (k = 0; k < 256; k++)
      {
         c = k;
         for (b = 0; b < 8; b++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
         ra3d_match_crc_tab[k] = c;
      }
      ra3d_match_crc_ready = 1;
   }
   for (i = 0; i < n; i++) crc = ra3d_match_crc_tab[(crc ^ d[i]) & 0xFF] ^ (crc >> 8);
   return crc;
}

static void ra3d_match_set_add(Ra3dRomTiles *rt, const uint8_t *chr)
{
   uint64_t h; uint32_t i;
   if (ra3d_match_tile_solid(chr)) return;
   h = ra3d_match_tile_hash(chr);
   i = (uint32_t)h & rt->mask;
   while (rt->slots[i])
   {
      if (rt->slots[i] == h) return;
      i = (i + 1) & rt->mask;
   }
   rt->slots[i] = h;
   rt->count++;
}

int ra3d_match_rom_scan(const uint8_t *rom, size_t len, Ra3dRomTiles *rt)
{
   size_t hdr = 0, prg_off, prg = 0, chr = 0, i, want, cap;
   memset(rt, 0, sizeof(*rt));
   if (!rom || len < 16) return 0;
   if (len >= 16 && rom[0] == 'N' && rom[1] == 'E' && rom[2] == 'S' && rom[3] == 0x1A)
   {
      size_t pu = rom[4], cu = rom[5];
      rt->ines = 1;
      hdr = 16;
      if ((rom[7] & 0x0C) == 0x08)   /* NES 2.0: size MSB nibbles (plain form only) */
      {
         if ((rom[9] & 0x0F) != 0x0F) pu |= (size_t)(rom[9] & 0x0F) << 8;
         if ((rom[9] >> 4)   != 0x0F) cu |= (size_t)(rom[9] >> 4) << 8;
      }
      prg = pu * 16384; chr = cu * 8192;
      /* 3dSen's ROM CRC: CHR (or 32 KB of zeros for CHR-RAM) then PRG, read
       * straight after the 16-byte header (no trainer skip) */
      {
         size_t p3 = prg < len - 16 ? prg : len - 16;
         size_t c3off = 16 + p3, c3 = 0;
         uint32_t c = 0xFFFFFFFFu;
         if (cu) { c3 = chr < len - c3off ? chr : len - c3off; c = ra3d_match_crc(c, rom + c3off, c3); }
         else
         {
            static const uint8_t z[1024] = {0}; int k;
            for (k = 0; k < 32; k++) c = ra3d_match_crc(c, z, sizeof(z));
         }
         c = ra3d_match_crc(c, rom + 16, p3);
         rt->crc_3dsen = c ^ 0xFFFFFFFFu;
      }
      if (rom[6] & 4) hdr += 512;   /* trainer */
   }
   if (hdr > len) hdr = len;
   prg_off = hdr;
   if (!rt->ines) prg = len;          /* headerless: everything is "PRG" */
   if (prg > len - prg_off) prg = len - prg_off;
   if (chr > len - prg_off - prg) chr = len - prg_off - prg;
   rt->prg = (uint32_t)prg; rt->chr = (uint32_t)chr;
   rt->crc_nointro = ra3d_match_crc(0xFFFFFFFFu, rom + hdr, len - hdr) ^ 0xFFFFFFFFu;

   want = (prg >= 16 ? prg - 15 : 0) + chr / 16;
   cap = 1024; while (cap < want * 2 && cap < ((size_t)1 << 24)) cap <<= 1;
   if (want * 2 > cap) return 0;   /* > 8M windows: refuse, never probe a full table */
   rt->slots = (uint64_t *)calloc(cap, sizeof(uint64_t));
   if (!rt->slots) return 0;
   rt->mask = (uint32_t)(cap - 1);
   for (i = 0; i + 16 <= chr; i += 16) ra3d_match_set_add(rt, rom + prg_off + prg + i);
   for (i = 0; i + 16 <= prg; i++)     ra3d_match_set_add(rt, rom + prg_off + i);
   return 1;
}

void ra3d_match_rom_free(Ra3dRomTiles *rt)
{
   if (!rt) return;
   free(rt->slots);
   rt->slots = NULL;
}

static int ra3d_match_has(const Ra3dRomTiles *rt, uint64_t h)
{
   uint32_t i = (uint32_t)h & rt->mask;
   while (rt->slots[i])
   {
      if (rt->slots[i] == h) return 1;
      i = (i + 1) & rt->mask;
   }
   return 0;
}

void ra3d_match_score(const Ra3dRomTiles *rt, const uint64_t *tiles,
                      uint32_t ntiles, Ra3dMatchScore *out)
{
   uint32_t i, f = 0;
   if (rt && rt->slots)
      for (i = 0; i < ntiles; i++) f += (uint32_t)ra3d_match_has(rt, tiles[i]);
   out->found  = f;
   out->ntiles = ntiles;
   out->cov    = ntiles ? (double)f / (double)ntiles : 0.0;
}

int ra3d_match_eligible(const Ra3dMatchScore *s, double min_cov)
{
   return s->ntiles >= RA3D_MATCH_MIN_SIG && s->found >= RA3D_MATCH_MIN_FOUND
       && s->cov >= min_cov;
}

int ra3d_match_better(const Ra3dMatchScore *a, const char *an,
                      const Ra3dMatchScore *b, const char *bn)
{
   double d = a->cov - b->cov;
   if (d >  RA3D_MATCH_NEAR) return 1;
   if (d < -RA3D_MATCH_NEAR) return 0;
   if (a->found != b->found) return a->found > b->found;
   if (a->cov != b->cov)     return a->cov > b->cov;
   return strcmp(an ? an : "", bn ? bn : "") < 0;
}

#ifdef RA3D_SHAPE_IMPLEMENTATION
int ra3d_match_profile_tiles(const Ra3dProfile *p, uint64_t **out, uint32_t *n)
{
   uint32_t i, k = 0;
   uint64_t *v;
   *out = NULL; *n = 0;
   if (!p) return 0;
   v = (uint64_t *)malloc((size_t)(p->vars.n ? p->vars.n : 1) * sizeof(uint64_t));
   if (!v) return 0;
   for (i = 0; i < p->vars.n; i++)
      if (!ra3d_match_tile_solid(p->vars.v[i].chr))
         v[k++] = ra3d_match_tile_hash(p->vars.v[i].chr);
   *n = ra3d_match_sort_unique(v, k);
   *out = v;
   return 1;
}
#endif

#endif /* RA3D_MATCH_IMPLEMENTED */
#endif /* RA3D_MATCH_IMPLEMENTATION */
