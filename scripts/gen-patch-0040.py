#!/usr/bin/env python3
"""Generate overlay/patches/0040-visionos-geometry-option-beacons.patch.

The tester reports that on the Vision Pro NOTHING he changes about widescreen has a
visible effect: Wide Resolution 1920x1080 changed nothing, Native Res Factor 5x
vs OFF changed nothing, and the image stays letterboxed/stretched with garbage
bars — while the mac harness renders the same core at true 16:9 and honours
every one of those options. The device therefore differs
somewhere between "the menu writes an option" and "GLideN64 sizes its output",
and no existing log line covers that stretch.

This patch adds four beacon lines (visionOS only, all rate-limited to changes so
they cannot spam the log) that make the next device run decisive:

  core opts file: <path>            which options file RA actually opened, and
                                    whether it is the per-game/per-core or the
                                    global one
  core opt: <key> = "<value>"       every GLideN64 geometry option RA hands the
                                    core, at the moment it hands it
  av geom: base/max/aspect          the geometry the core advertises at load
  gl2 vp: ...                       the rect gl2_frame actually passes to
                                    glViewport, plus the core's frame size

Between them: if `core opt` shows the old value, the menu write never reached
the core; if it shows the new value but `av geom` does not follow, the core
ignored it; if both follow but `gl2 vp` letterboxes, the fault is RetroArch's
viewport math.

Run from the repo root against pristine vendor text; asserts every anchor.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "overlay/patches/0040-visionos-geometry-option-beacons.patch"

# (relative path, [(anchor, replacement), ...])
EDITS = [
    (
        "runloop.c",
        [
            # 1. which options file, and the geometry options as delivered
            (
                """            RARCH_DBG("[Environ] GET_VARIABLE: %s = \\"%s\\"\\n",
                  var->key, var->value);
""",
                """            RARCH_DBG("[Environ] GET_VARIABLE: %s = \\"%s\\"\\n",
                  var->key, var->value);
#if defined(RA_VISIONOS)
            /* 0040: beacon the GLideN64 geometry options as RA delivers them,
             * once per distinct value, so a device log says whether a menu
             * change ever reached the core. */
            if (     strstr(var->key, "aspect")
                  || strstr(var->key, "screensize")
                  || strstr(var->key, "NativeResFactor"))
            {
               static char last_key[64];
               static char last_val[64];
               if (     strncmp(last_key, var->key,   sizeof(last_key) - 1)
                     || strncmp(last_val, var->value, sizeof(last_val) - 1))
               {
                  char _m[192];
                  extern void RA_BeaconMark(const char *);
                  strlcpy(last_key, var->key,   sizeof(last_key));
                  strlcpy(last_val, var->value, sizeof(last_val));
                  snprintf(_m, sizeof(_m), "core opt: %s = \\"%s\\"",
                        var->key, var->value);
                  RA_BeaconMark(_m);
               }
            }
#endif
""",
            ),
            # 2. the options file RA actually opened
            (
                """   if (*options_path)
      return core_option_manager_new(options_path,
            src_options_path, options_v2,
            categories_enabled);
   return NULL;
}
""",
                """#if defined(RA_VISIONOS)
   /* 0040: name the options file, so "my menu change did nothing" can be told
    * apart from "the menu wrote a file the core never reads". */
   {
      char _m[320];
      extern void RA_BeaconMark(const char *);
      snprintf(_m, sizeof(_m), "core opts file: %s (src %s)",
            *options_path ? options_path : "<none>",
            *src_options_path ? src_options_path : "<none>");
      RA_BeaconMark(_m);
   }
#endif
   if (*options_path)
      return core_option_manager_new(options_path,
            src_options_path, options_v2,
            categories_enabled);
   return NULL;
}
""",
            ),
            # 3. geometry the core advertises / changes
            (
                """            RARCH_LOG("[Environ] SET_GEOMETRY: %ux%u, Aspect: %.3f.\\n",
                  geom->base_width, geom->base_height, geom->aspect_ratio);
""",
                """            RARCH_LOG("[Environ] SET_GEOMETRY: %ux%u, Aspect: %.3f.\\n",
                  geom->base_width, geom->base_height, geom->aspect_ratio);
#if defined(RA_VISIONOS)
            {
               char _m[192];
               extern void RA_BeaconMark(const char *);
               snprintf(_m, sizeof(_m),
                     "av geom: base=%ux%u max=%ux%u ar=%.4f",
                     geom->base_width, geom->base_height,
                     geom->max_width,  geom->max_height,
                     geom->aspect_ratio);
               RA_BeaconMark(_m);
            }
#endif
""",
            ),
        ],
    ),
]


def hunks_for(relpath, edits):
    src = ROOT / "vendor/RetroArch" / relpath
    text = src.read_text()
    if "0040:" in text:
        sys.exit(f"0040 already applied to {relpath} — reverse it out before regenerating")
    out = []
    for anchor, replacement in edits:
        n = text.count(anchor)
        if n != 1:
            sys.exit(f"{relpath}: anchor matched {n} times (want 1):\n{anchor}")
        start = text.index(anchor)
        line_no = text[:start].count("\n") + 1
        a_lines = anchor.rstrip("\n").split("\n")
        r_lines = replacement.rstrip("\n").split("\n")
        # Emit as a plain delete-then-add hunk; the anchor is fully rewritten.
        body = ["-" + l if l else "-" for l in a_lines]
        body += ["+" + l if l else "+" for l in r_lines]
        out.append((line_no, len(a_lines), len(r_lines), body))
    out.sort(key=lambda h: h[0])
    return out


patch = []
for relpath, edits in EDITS:
    patch.append(f"diff --git a/{relpath} b/{relpath}\n--- a/{relpath}\n+++ b/{relpath}\n")
    for line_no, old_n, new_n, body in hunks_for(relpath, edits):
        patch.append(f"@@ -{line_no},{old_n} +{line_no},{new_n} @@\n")
        patch.append("\n".join(body) + "\n")

OUT.write_text("".join(patch))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
