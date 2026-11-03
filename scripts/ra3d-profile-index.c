/* ra3d-profile-index.c — build / test the bundled 3dSen profile index.
 *
 *   ra3d-profile-index build <out/index.bin> <profile.3dn>...
 *       Parses every profile with the SHIPPED parser (ra3d_shape.h) and writes
 *       each one's tile signature (ra3d_match.h). A profile that does not
 *       parse (e.g. the official `empty.3dn`) is written with 0 tiles, so the
 *       index always lists every bundled file. Exit 1 on any I/O failure.
 *
 *   ra3d-profile-index match <index.bin> <rom>...
 *       Mac check of the run-time decision: per ROM, the top 3 by the winner
 *       rule, the verdict at the default threshold and the scan cost.
 *
 * Built and run by scripts/stage-3dsen-profiles.sh (host cc). Harness/build
 * tool only; it never ships.
 */
#define RA3D_SHAPE_IMPLEMENTATION
#include "ra3d_shape.h"
#define RA3D_MATCH_IMPLEMENTATION
#include "ra3d_match.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static void *slurp(const char *path, size_t *n)
{
   FILE *f = fopen(path, "rb");
   long sz; void *b;
   if (!f) return NULL;
   fseek(f, 0, SEEK_END); sz = ftell(f); fseek(f, 0, SEEK_SET);
   b = malloc(sz > 0 ? (size_t)sz : 1);
   if (b && sz > 0 && fread(b, 1, (size_t)sz, f) != (size_t)sz) { free(b); b = NULL; }
   fclose(f);
   *n = sz > 0 ? (size_t)sz : 0;
   return b;
}

static void put_u16(FILE *f, unsigned v) { fputc(v & 0xFF, f); fputc((v >> 8) & 0xFF, f); }
static void put_u32(FILE *f, uint32_t v) { int i; for (i = 0; i < 4; i++) fputc((v >> (8 * i)) & 0xFF, f); }
static void put_u64(FILE *f, uint64_t v) { int i; for (i = 0; i < 8; i++) fputc((int)((v >> (8 * i)) & 0xFF), f); }

static double now_ms(void)
{
   struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
   return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static int build(const char *out, int n, char **files)
{
   FILE *f = fopen(out, "wb");
   int i, total = 0;
   if (!f) { perror(out); return 1; }
   fwrite(RA3D_MATCH_INDEX_MAGIC, 1, 8, f);
   put_u32(f, (uint32_t)n);
   for (i = 0; i < n; i++)
   {
      size_t len; char err[128] = {0}, id[32];
      void *d = slurp(files[i], &len);
      const char *base = strrchr(files[i], '/');
      Ra3dProfile *p;
      uint64_t *t = NULL; uint32_t nt = 0, j;
      base = base ? base + 1 : files[i];
      if (!d) { fprintf(stderr, "FATAL: cannot read %s\n", files[i]); fclose(f); return 1; }
      if (strlen(base) >= 128) { fprintf(stderr, "FATAL: name too long %s\n", base); fclose(f); return 1; }
      ra3d_match_profile_id(d, len, id, sizeof(id));
      p = ra3d_profile_parse(d, len, err, sizeof(err));
      if (p) ra3d_match_profile_tiles(p, &t, &nt);
      else   fprintf(stderr, "  note: %s does not parse (%s) - indexed with 0 tiles\n", base, err);
      put_u16(f, (unsigned)strlen(base)); fwrite(base, 1, strlen(base), f);
      put_u16(f, (unsigned)strlen(id));   fwrite(id, 1, strlen(id), f);
      put_u32(f, nt);
      for (j = 0; j < nt; j++) put_u64(f, t[j]);
      total += (int)nt;
      free(t);
      if (p) ra3d_profile_free(p);
      free(d);
   }
   if (fclose(f)) { perror(out); return 1; }
   printf("index: %d profiles, %d tile hashes -> %s\n", n, total, out);
   return 0;
}

static int match(const char *ixpath, int n, char **roms)
{
   size_t len; char err[128];
   void *d = slurp(ixpath, &len);
   Ra3dMatchIndex *ix = d ? ra3d_match_index_load(d, len, err, sizeof(err)) : NULL;
   int i;
   free(d);
   if (!ix) { fprintf(stderr, "index: %s\n", d ? err : "unreadable"); return 1; }
   for (i = 0; i < n; i++)
   {
      size_t rl; uint8_t *rom = (uint8_t *)slurp(roms[i], &rl);
      Ra3dRomTiles rt; Ra3dMatchScore best[3]; int bi[3] = { -1, -1, -1 };
      uint32_t k; int r; double t0, t1, t2;
      const char *base = strrchr(roms[i], '/');
      base = base ? base + 1 : roms[i];
      if (!rom) { printf("%-44.44s unreadable\n", base); continue; }
      t0 = now_ms();
      ra3d_match_rom_scan(rom, rl, &rt);
      t1 = now_ms();
      for (k = 0; k < ix->n; k++)
      {
         Ra3dMatchScore s;
         ra3d_match_score(&rt, ix->e[k].tiles, ix->e[k].ntiles, &s);
         if (s.ntiles < RA3D_MATCH_MIN_SIG) continue;
         for (r = 0; r < 3; r++)
            if (bi[r] < 0 || ra3d_match_better(&s, ix->e[k].name, &best[r], ix->e[bi[r]].name))
            {
               int q;
               for (q = 2; q > r; q--) { best[q] = best[q - 1]; bi[q] = bi[q - 1]; }
               best[r] = s; bi[r] = (int)k; break;
            }
      }
      t2 = now_ms();
      printf("%-44.44s crc %08X 3dsen %08X prg %6u chr %6u tiles %6u scan %.1f ms score %.2f ms -> %s",
             base, rt.crc_nointro, rt.crc_3dsen, rt.prg, rt.chr, rt.count, t1 - t0, t2 - t1,
             (bi[0] >= 0 && ra3d_match_eligible(&best[0], RA3D_MATCH_MIN_COV)) ? ix->e[bi[0]].name : "NONE");
      for (r = 0; r < 3; r++)
         if (bi[r] >= 0)
            printf(" | %s %.3f %u/%u", ix->e[bi[r]].name, best[r].cov, best[r].found, best[r].ntiles);
      printf("\n");
      ra3d_match_rom_free(&rt);
      free(rom);
   }
   ra3d_match_index_free(ix);
   return 0;
}

int main(int argc, char **argv)
{
   if (argc >= 4 && !strcmp(argv[1], "build")) return build(argv[2], argc - 3, argv + 3);
   if (argc >= 4 && !strcmp(argv[1], "match")) return match(argv[2], argc - 3, argv + 3);
   fprintf(stderr, "usage: ra3d-profile-index build <out.bin> <p.3dn>... | match <index.bin> <rom>...\n");
   return 2;
}
