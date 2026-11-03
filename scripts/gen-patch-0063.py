#!/usr/bin/env python3
"""Generate overlay/patches/0063-visionos-config-heal-dead-container.patch.

The fix for that, written here.

THE BUG. iOS and visionOS RELOCATE an app's data container on every install —
`/Containers/Data/Application/<UUID>/` gets a NEW UUID (the tester's
`launch-beacon.log` carries 13 of them). `retroarch.cfg` is written non-minimal
by default (`config.def.h:625`), so every directory is persisted as an ABSOLUTE
path and re-applied blind by the path-settings loop that ends just above this
patch. Upstream existence-checks `screenshot_directory` (:6717),
`savefile_directory` (:6900) and `savestate_directory` (:6921) — which therefore
self-heal — but NOT `system_directory` (:1691) or `playlist_directory` (:1689).
One install after the config was last saved, those two point into a container
that no longer exists: BIOS lookups (flycast's `dc_boot.bin`), Mesen HD packs,
and the whole playlist/recent-content list read from a dead path, forever.

The tester's device is in exactly that state. 's log, three loads at
17:56-17:57, all say:

  hdpack: rom="..." hdpacks=".../Application/2EF49E4F-.../Documents/RetroArch/system/HdPacks"
  hdpack: HdPacks UNREADABLE (No such file or directory) — diagnosing
  hdpack:   home=".../Application/2EF49E4F-..."

i.e. on THAT log the configured path is under the LIVE container (0061's `home=`
line is what proves it), so his particular ENOENT was the casing, not staleness
— see /overlay 0062. The stale-path bug is real all the same, it is the
one upstream has no check for, and it is the reason 0061 needed a fallback at
all. This heals it at the source instead.

THE FIX (upstream-idiomatic, deliberately conservative). Immediately after the
generic path-load loop, beside upstream's own `#if !IOS libretro_directory`
guard — which exists for the SAME reason, the bundle path moving every install
— reset `directory_system` and `directory_playlist` to their live defaults when
ALL of the following hold:

  1. the value is non-empty and not the literal "default";
  2. it contains "/Containers/Data/Application/" (so it names an app data
     container; a path anywhere else is the user's business);
  3. it is NOT under the live container ($HOME) — a user who deliberately
     pointed these somewhere else inside the live container keeps his choice;
  4. `path_is_directory()` says it is not there.

Each reset writes one `config heal:` line to Documents/launch-beacon.log via
RA_BeaconMark (ui_cocoatouch.m) and one RARCH_WARN to retroarch.log, naming the
setting, the dead path and the replacement. Silent on a healthy config.

Gated `#if defined(__APPLE__) && TARGET_OS_IPHONE` (true for both the iOS and
the visionOS slice), so no other platform sees a byte of it.

NOT done here, deliberately: the prefix-REWRITE variant, which would also repair
the absolute ROM paths recorded inside `playlists/*.lpl`. (d) calls for the
reset first; the rewrite is a bigger patch and a separate decision.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "configuration.c"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0063-visionos-config-heal-dead-container.patch"

ANCHOR = """#if !IOS
   if (config_get_path(conf, "libretro_directory", tmp_str, sizeof(tmp_str)))
      configuration_set_string(settings,
            settings->paths.directory_libretro, tmp_str);
#endif
"""

REPL = r'''#if !IOS
   if (config_get_path(conf, "libretro_directory", tmp_str, sizeof(tmp_str)))
      configuration_set_string(settings,
            settings->paths.directory_libretro, tmp_str);
#endif

#if defined(__APPLE__) && TARGET_OS_IPHONE
   /* 0063 (the fix (d) specified): iOS/visionOS RELOCATE the data
    * container on every install, retroarch.cfg persists directories as ABSOLUTE
    * paths, and the loop above re-applies them blind. Upstream existence-checks
    * screenshot_directory (below), savefile_directory and savestate_directory —
    * so those self-heal — but NOT system_directory or playlist_directory, which
    * then point one install behind, forever: dead BIOS lookups (flycast), dead
    * HD-pack lookups (Mesen), an empty recent-content list.
    *
    * The same reason upstream ignores a saved libretro_directory on iOS, just
    * above. Conservative on purpose: a path is healed ONLY when it names some
    * app data container, is not under the LIVE one, and is not there any more —
    * a user who deliberately pointed these elsewhere inside the live container
    * keeps his choice, and a healthy config prints nothing. */
#define RA_HEAL_DEAD_DIR(dirvar, defdir, ident) \
   do \
   { \
      const char *ra_live = getenv("HOME"); \
      const char *ra_def  = (defdir); \
      if (     *(dirvar) \
            && !string_is_equal((dirvar), "default") \
            && strstr((dirvar), "/Containers/Data/Application/") \
            && !(ra_live && !strncmp((dirvar), ra_live, strlen(ra_live))) \
            && !path_is_directory((dirvar))) \
      { \
         char ra_msg[512]; \
         extern void RA_BeaconMark(const char *); \
         snprintf(ra_msg, sizeof(ra_msg), \
               "config heal: \"%s\" pointed into a dead data container " \
               "(\"%s\") -> \"%s\"", (ident), (dirvar), \
               *ra_def ? ra_def : "(cleared)"); \
         RARCH_WARN("[Config] %s\n", ra_msg); \
         RA_BeaconMark(ra_msg); \
         if (*ra_def) \
         { \
            configuration_set_string(settings, (dirvar), ra_def); \
         } \
         else \
            *(dirvar) = '\0'; \
      } \
   } while (0)

   RA_HEAL_DEAD_DIR(settings->paths.directory_system,
         g_defaults.dirs[DEFAULT_DIR_SYSTEM],   "system_directory");
   RA_HEAL_DEAD_DIR(settings->paths.directory_playlist,
         g_defaults.dirs[DEFAULT_DIR_PLAYLIST], "playlist_directory");

#undef RA_HEAL_DEAD_DIR
#endif
'''

text = SRC.read_text()
if "RA_HEAL_DEAD_DIR" in text:
    sys.exit("0063 already applied to vendor — reverse it out before regenerating")
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1
old_lines = ANCHOR.rstrip("\n").split("\n")
new_lines = REPL.rstrip("\n").split("\n")
LEAD = TRAIL = 3
lead = text[:start].split("\n")[:-1][-LEAD:]
rest = text[start + len(ANCHOR):].split("\n")[:TRAIL]
while rest and rest[-1] == "":
    rest.pop()

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
    ["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
