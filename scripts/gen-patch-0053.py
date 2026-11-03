#!/usr/bin/env python3
"""Generate overlay/patches/0053-cores-bsnes-hd-xros-widescreen-all.patch.

ITEM 3 of the polish round: widescreen SNES.

What was ALREADY true, from the source (no patch needed for any of it):

- bsnes-hd's widescreen extension is ON at upstream's own defaults:
  `bsnes_mode7_scale = "2x"` (widescreen is disabled only when the HD Mode 7
  scale is `disable`, `libretro.cpp:424`: `if (scale == 0) ws = 0;`) and
  `bsnes_mode7_widescreen = "16:9"`.
- The core REPORTS the widened geometry, so nothing frontend-side has to be
  taught about it. `HdToolkit::determineWsExt()` (`emulator/hdtoolkit.hpp`) turns
  `16:9` into a per-side extension of 64 px, and `retro_get_system_av_info()`
  (`target-libretro/libretro.cpp:898`) reports
  `base_width = (256 + 2*64) * scale = 384 * scale` against
  `base_height = 216 * scale` — exactly 16:9 — and re-issues it through
  `SET_SYSTEM_AV_INFO` whenever the setting changes (`update_geometry()`).
  With pixel-aspect correction on the numbers differ (ext 40, 336x216) but
  `aspect_ratio = 8/7 * 336/216` is 16:9 again.
- RetroArch's own default is `DEFAULT_ASPECT_RATIO_IDX = ASPECT_RATIO_CORE`
  (`config.def.h:594`), so `video_st->aspect_ratio` follows that geometry, and
  the visionOS window follows `video_st->aspect_ratio` (overlay 0015 +
  `ra_vision_arm_aspect_lock()`, item 2). The aspect lock is therefore already
  per-core and needs no bsnes special-casing: 16:9 while bsnes-hd is widescreen,
  4:3 for the other software cores, driven by the core's reported geometry.

The ONE thing that is not what the tester asked for: upstream defaults
`bsnes_mode7_wsMode` to `"Mode 7"`, i.e. the picture only widens on Mode 7
scenes (Mario Kart's track, F-Zero, the Mode 7 maps). Most SNES games are not
Mode 7, so "widescreen SNES" out of the box is, in practice, "4:3 SNES with a
widescreen Mario Kart".

THE PATCH: for this port's xros slice only (`-DBSNES_XROS_WIDESCREEN`, passed by
scripts/build-core-xros.sh; the shape is overlay 0016's, which does the same
thing to mupen64plus-next's compiled defaults), change that one default to
`"all"`. Everything else stays exactly as DerKoun shipped it, because his
defaults are already the artifact-minimising ones and they matter more under
`"all"` than under `"Mode 7"`:

  bsnes_mode7_wsobj  = "safe"     sprites only extend into the new area when
                                  they can be shown to belong there
  bsnes_mode7_igwin  = "outside"  window (mask) effects ignored outside the
                                  original 256 px, so HUD masks do not smear
  bsnes_mode7_wsbg1..4 = "auto horz and vert"
  bsnes_mode7_wsMarker = "none"

DEFAULT, not forced (contrast 0051, which had to force because the device
already had a persisted value): nothing has ever run bsnes-hd on the tester's
headset, so there is no `bsnes_hd_beta_libretro.opt` to lose to — and this is a
taste setting, so a default he can change in Core Options is the right kind of
change. Per-game quality genuinely varies; the two-click path back is
`"Mode 7"` or `"none"` in Core Options.

NOT VERIFIED ON CONTENT: there is no SNES ROM in this repo or on this machine
and the mac harness is
mupen-only. What IS verified is that the option string reaches the shipped
binary (`strings` on the built framework) and the geometry arithmetic above,
which is read off the source. Device verification is the tester's.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/bsnes-hd-beta/bsnes/target-libretro/libretro_core_options.h"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0053-cores-bsnes-hd-xros-widescreen-all.patch"

ANCHOR = """         { "none",   "disabled"               },
         { NULL, NULL },
      },
      "Mode 7"
   },
"""

REPLACEMENT = """         { "none",   "disabled"               },
         { NULL, NULL },
      },
      /* 0053: this port's visionOS slice widens EVERY scene, not only Mode 7 —
       * "widescreen SNES" is what was asked for, and Mode-7-only leaves the
       * great majority of the library at 4:3. Upstream's default is kept for
       * every other platform. The flanking defaults that keep "all" clean
       * (wsobj=safe, igwin=outside, wsbg*=auto horz and vert, wsMarker=none)
       * are DerKoun's own and are deliberately untouched. Per-game quality
       * varies: */
#if defined(BSNES_XROS_WIDESCREEN)
      "all"
#else
      "Mode 7"
#endif
   },
"""

text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "BSNES_XROS_WIDESCREEN" in text:
    sys.exit("0053 already applied to vendor — reverse it out before regenerating")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1
old_lines = ANCHOR.rstrip("\n").split("\n")
new_lines = REPLACEMENT.rstrip("\n").split("\n")
LEAD = 3
TRAIL = 3
lead = text[:start].rstrip("\n").split("\n")[-LEAD:]
rest = text[start + len(ANCHOR):].split("\n")[:TRAIL]

body = [" " + l if l else " " for l in lead]
body += ["-" + l if l else "-" for l in old_lines]
body += ["+" + l if l else "+" for l in new_lines]
body += [" " + l if l else " " for l in rest]
old_count = len(lead) + len(old_lines) + len(rest)
new_count = len(lead) + len(new_lines) + len(rest)
hunk_start = line_no - len(lead)

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n"
    f"--- a/{REL}\n"
    f"+++ b/{REL}\n"
    f"@@ -{hunk_start},{old_count} +{hunk_start},{new_count} @@\n"
    + "\n".join(body) + "\n"
)
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/bsnes-hd-beta"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
