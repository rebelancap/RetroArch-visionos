/* ra3d_camstore.h — the per-game 3D camera file.
 *
 *   #define RA3D_CAMSTORE_IMPLEMENTATION
 *   #include "ra3d_camstore.h"
 *
 * `Documents/RetroArch/system/3dsen/camera-state.cfg`, one game per line:
 *
 *   # comments and blank lines are kept out of the parse
 *   id:smb1          yaw=-12.50 pitch=8.00 zoom=1.2500 panx=0.0000 pany=0.0000
 *   crc:3337EC46     yaw=0.00 pitch=-20.00 zoom=0.8000 panx=0.1200 pany=0.0000
 *
 * The key is `id:<3dSen profile Id>` when a profile matched (sanitised to
 * [A-Za-z0-9._-]) or `crc:<No-Intro CRC32 of the ROM>` otherwise. The values
 * are the USER's camera as an offset from the home pose (the profile's own or
 * the Lua-scripted one): yaw/pitch in degrees added to home, zoom a
 * multiplier of the home zoom, pan in metres — exactly the integrator's
 * targets less its home. Deleting the file resets every game.
 *
 * Parsing is forgiving per line and strict per value: a line without all five
 * fields, with a non-finite or out-of-range value, or with a key that does not
 * fit, is ignored (and so dropped at the next save). A later line for the same
 * key wins. Writing is atomic (write `<path>.tmp`, fsync, rename).
 *
 * Pure C and header-only so the mac harness unit-tests the exact code
 *
 */
#ifndef RA3D_CAMSTORE_H
#define RA3D_CAMSTORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RA3D_CAMSTORE_KEY_MAX 64
#define RA3D_CAMSTORE_MAX     512   /* games kept; the oldest line drops beyond */

typedef struct
{
   char  key[RA3D_CAMSTORE_KEY_MAX];
   float yaw, pitch;   /* degrees, offset from home   */
   float zoom;         /* multiplier of the home zoom */
   float panx, pany;   /* metres                      */
} Ra3dCamEntry;

typedef struct
{
   Ra3dCamEntry e[RA3D_CAMSTORE_MAX];
   int          n;
} Ra3dCamStore;

/* Parses `len` bytes (need not be NUL-terminated). Returns the entries kept;
 * *bad (optional) counts non-comment lines ignored as malformed. */
int  ra3d_camstore_parse(Ra3dCamStore *s, const char *buf, size_t len, int *bad);
/* Formats the store (header comment + one line per entry). Returns the length
 * written (excluding the NUL), or -1 if `cap` is too small. */
int  ra3d_camstore_format(const Ra3dCamStore *s, char *out, size_t cap);
const Ra3dCamEntry *ra3d_camstore_find(const Ra3dCamStore *s, const char *key);
/* Inserts or replaces (moves it to the end: most recent last). 0 if the entry
 * is invalid (bad key or values). */
int  ra3d_camstore_put(Ra3dCamStore *s, const Ra3dCamEntry *e);
/* `id:<profile id>` (sanitised) or, when the id is empty, `crc:%08X`.
 * Returns 0 if neither is available (no id and have_crc == 0). */
int  ra3d_camstore_key(char out[RA3D_CAMSTORE_KEY_MAX], const char *profile_id,
                       unsigned crc, int have_crc);
int  ra3d_camstore_valid(const Ra3dCamEntry *e);
/* File I/O: load (a missing file is an empty store, returns 1) and the atomic
 * save. Both return 0 on an I/O error. */
int  ra3d_camstore_load(Ra3dCamStore *s, const char *path, int *bad);
int  ra3d_camstore_save(const Ra3dCamStore *s, const char *path);

#ifdef __cplusplus
}
#endif

/* ========================================================================== */
#ifdef RA3D_CAMSTORE_IMPLEMENTATION

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <fcntl.h>

static int ra3d_camstore_keych(char c)
{
   return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
       || c == '.' || c == '_' || c == '-' || c == ':';
}

int ra3d_camstore_valid(const Ra3dCamEntry *e)
{
   size_t i, n;
   if (!e) return 0;
   n = strnlen(e->key, RA3D_CAMSTORE_KEY_MAX);
   if (n == 0 || n >= RA3D_CAMSTORE_KEY_MAX) return 0;
   for (i = 0; i < n; i++)
      if (!ra3d_camstore_keych(e->key[i])) return 0;
   if (!isfinite(e->yaw) || !isfinite(e->pitch) || !isfinite(e->zoom) ||
       !isfinite(e->panx) || !isfinite(e->pany))
      return 0;
   /* generous sanity bounds — the live clamps are applied on restore */
   if (fabsf(e->yaw) > 360.0f || fabsf(e->pitch) > 360.0f) return 0;
   if (e->zoom < 0.01f || e->zoom > 100.0f) return 0;
   if (fabsf(e->panx) > 100.0f || fabsf(e->pany) > 100.0f) return 0;
   return 1;
}

const Ra3dCamEntry *ra3d_camstore_find(const Ra3dCamStore *s, const char *key)
{
   int i;
   if (!s || !key) return NULL;
   for (i = s->n - 1; i >= 0; i--)
      if (!strcmp(s->e[i].key, key)) return &s->e[i];
   return NULL;
}

int ra3d_camstore_put(Ra3dCamStore *s, const Ra3dCamEntry *e)
{
   int i;
   if (!s || !ra3d_camstore_valid(e)) return 0;
   for (i = 0; i < s->n; i++)
      if (!strcmp(s->e[i].key, e->key))
      {
         memmove(&s->e[i], &s->e[i + 1], (size_t)(s->n - i - 1) * sizeof(s->e[0]));
         s->n--;
         break;
      }
   if (s->n >= RA3D_CAMSTORE_MAX)
   {
      memmove(&s->e[0], &s->e[1], (size_t)(s->n - 1) * sizeof(s->e[0]));
      s->n--;
   }
   s->e[s->n++] = *e;
   return 1;
}

/* one line, NUL-terminated, comments already excluded */
static int ra3d_camstore_line(const char *ln, Ra3dCamEntry *out)
{
   const char *p = ln, *k0;
   size_t kn;
   int have = 0;
   memset(out, 0, sizeof(*out));
   while (*p == ' ' || *p == '\t') p++;
   k0 = p;
   while (*p && *p != ' ' && *p != '\t') p++;
   kn = (size_t)(p - k0);
   if (kn == 0 || kn >= RA3D_CAMSTORE_KEY_MAX) return 0;
   memcpy(out->key, k0, kn); out->key[kn] = 0;
   for (;;)
   {
      const char *n0, *eq;
      char *end;
      float v;
      size_t nn;
      while (*p == ' ' || *p == '\t') p++;
      if (!*p) break;
      n0 = p;
      while (*p && *p != '=' && *p != ' ' && *p != '\t') p++;
      if (*p != '=') return 0;
      eq = p; nn = (size_t)(eq - n0);
      v = strtof(eq + 1, &end);
      if (end == eq + 1 || (*end && *end != ' ' && *end != '\t')) return 0;
      p = end;
#define RA3D_CS_FIELD(name, bit, dst) \
      if (nn == sizeof(name) - 1 && !memcmp(n0, name, nn)) { out->dst = v; have |= bit; continue; }
      RA3D_CS_FIELD("yaw",   1,  yaw)
      RA3D_CS_FIELD("pitch", 2,  pitch)
      RA3D_CS_FIELD("zoom",  4,  zoom)
      RA3D_CS_FIELD("panx",  8,  panx)
      RA3D_CS_FIELD("pany",  16, pany)
#undef RA3D_CS_FIELD
      /* an unknown field is tolerated (a later version's addition) */
   }
   return have == 31 && ra3d_camstore_valid(out);
}

int ra3d_camstore_parse(Ra3dCamStore *s, const char *buf, size_t len, int *bad)
{
   size_t i = 0;
   char ln[512];
   if (bad) *bad = 0;
   if (!s) return 0;
   s->n = 0;
   while (buf && i < len)
   {
      size_t j = i, n;
      const char *t;
      Ra3dCamEntry e;
      while (j < len && buf[j] != '\n' && buf[j] != '\r') j++;
      n = j - i;
      if (n < sizeof(ln))
      {
         memcpy(ln, buf + i, n); ln[n] = 0;
         t = ln;
         while (*t == ' ' || *t == '\t') t++;
         if (memchr(buf + i, 0, n))
         { if (bad) (*bad)++; }   /* an embedded NUL: binary junk */
         else if (*t && *t != '#' && *t != ';')
         {
            if (ra3d_camstore_line(ln, &e)) ra3d_camstore_put(s, &e);
            else if (bad) (*bad)++;
         }
      }
      else if (bad) (*bad)++;
      i = j;
      while (i < len && (buf[i] == '\n' || buf[i] == '\r')) i++;
   }
   return s->n;
}

int ra3d_camstore_format(const Ra3dCamStore *s, char *out, size_t cap)
{
   static const char hdr[] =
      "# 3D camera per game (RetroArch visionOS). Written by the app when you\n"
      "# leave 3D, close content or the app goes to the background; read on entering 3D.\n"
      "# Offsets from the game's home view: yaw/pitch degrees, zoom multiplier, pan metres.\n"
      "# Delete a line to reset that game, or this file to reset all. camera_persist = 0\n"
      "# in 3dsen.cfg stops reading and writing it.\n";
   size_t o = 0;
   int i, w;
   if (!out || cap < sizeof(hdr)) return -1;
   memcpy(out, hdr, sizeof(hdr) - 1); o = sizeof(hdr) - 1;
   for (i = 0; s && i < s->n; i++)
   {
      const Ra3dCamEntry *e = &s->e[i];
      if (!ra3d_camstore_valid(e)) continue;
      w = snprintf(out + o, cap - o, "%-24s yaw=%.3f pitch=%.3f zoom=%.4f panx=%.4f pany=%.4f\n",
                   e->key, (double)e->yaw, (double)e->pitch, (double)e->zoom,
                   (double)e->panx, (double)e->pany);
      if (w < 0 || (size_t)w >= cap - o) return -1;
      o += (size_t)w;
   }
   out[o] = 0;
   return (int)o;
}

int ra3d_camstore_key(char out[RA3D_CAMSTORE_KEY_MAX], const char *profile_id,
                      unsigned crc, int have_crc)
{
   out[0] = 0;
   if (profile_id && *profile_id)
   {
      size_t o = 3, i;
      memcpy(out, "id:", 3);
      for (i = 0; profile_id[i] && o < RA3D_CAMSTORE_KEY_MAX - 1; i++)
      {
         char c = profile_id[i];
         out[o++] = (ra3d_camstore_keych(c) && c != ':') ? c : '_';
      }
      out[o] = 0;
      return 1;
   }
   if (have_crc)
   {
      snprintf(out, RA3D_CAMSTORE_KEY_MAX, "crc:%08X", crc);
      return 1;
   }
   return 0;
}

int ra3d_camstore_load(Ra3dCamStore *s, const char *path, int *bad)
{
   FILE *f;
   char *buf;
   long n;
   if (bad) *bad = 0;
   s->n = 0;
   f = fopen(path, "rb");
   if (!f) return 1;                 /* no file = nothing saved yet */
   if (fseek(f, 0, SEEK_END) != 0 || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET) != 0)
   { fclose(f); return 0; }
   if (n > (1L << 20)) n = 1L << 20; /* a 1 MB cap; far beyond 512 lines */
   buf = (char *)malloc((size_t)n + 1);
   if (!buf) { fclose(f); return 0; }
   n = (long)fread(buf, 1, (size_t)n, f);
   fclose(f);
   ra3d_camstore_parse(s, buf, (size_t)n, bad);
   free(buf);
   return 1;
}

int ra3d_camstore_save(const Ra3dCamStore *s, const char *path)
{
   size_t cap = 1024 + (size_t)(s ? s->n : 0) * 160;
   char *buf = (char *)malloc(cap), tmp[1100];
   int len, fd, ok;
   if (!buf) return 0;
   len = ra3d_camstore_format(s, buf, cap);
   if (len < 0 || snprintf(tmp, sizeof(tmp), "%s.tmp", path) >= (int)sizeof(tmp))
   { free(buf); return 0; }
   fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
   if (fd < 0) { free(buf); return 0; }
   ok = write(fd, buf, (size_t)len) == len;
   ok = ok && fsync(fd) == 0;
   ok = (close(fd) == 0) && ok;
   free(buf);
   if (!ok || rename(tmp, path) != 0) { unlink(tmp); return 0; }
   return 1;
}

#endif /* RA3D_CAMSTORE_IMPLEMENTATION */
#endif /* RA3D_CAMSTORE_H */
