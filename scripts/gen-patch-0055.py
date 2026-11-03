#!/usr/bin/env python3
"""Generate overlay/patches/0055-visionos-heal-dead-container-dirs.patch.

 (d), finally written. iOS/visionOS RELOCATE an app's data container on
every install — `.../Containers/Data/Application/<new UUID>/` — and RetroArch
writes a non-minimal `retroarch.cfg` (config.def.h:625), so absolute container
paths are persisted and re-applied blind on the next load. Upstream already
existence-checks the three directories that matter most to it —
`screenshot_directory` (configuration.c, the block this patch follows),
`savefile_directory` and `savestate_directory` — and those self-heal.
`system_directory` and `playlist_directory` have no such check, so after a
relocation they can point into a container that no longer exists: BIOS lookups
(flycast's dc_boot.bin, mupen's PIF ROMs) fail and playlists read empty, one
install behind, forever, with no visible error.

THE PATCH, deliberately the narrowest possible version of the fix:

  * visionOS only (`#if TARGET_OS_VISION`) — the iOS target compiles upstream.
  * It fires ONLY when the configured path (a) is non-empty and not "default",
    (b) contains the literal `/Containers/Data/Application/`, i.e. is an
    iOS-style per-install container path, and (c) does not exist. A path outside
    a container — a Files-provider path, a user-chosen folder, an iCloud path —
    is never touched even when it is missing, because a missing network/provider
    path is a mount problem, not a stale one, and re-pointing it would be the
    wrong repair.
  * The repair is exactly upstream's own: point at `g_defaults.dirs[...]`, which
    is what a fresh install would have used, or clear the setting when there is
    no default.
  * It runs at config LOAD, so nothing is written back to disk unless RetroArch
    saves the config for its own reasons — the same lifecycle as the
    screenshot/savefile/savestate checks it sits next to.
  * Every repair leaves a `config heal:` line in Documents/launch-beacon.log
    naming the old and new path, so the next log says whether the tester's device
    was ever in this state at all.

Written defensively because the tester's `retroarch.cfg` has still not been read
(STATUS open question): the condition above cannot fire on a
healthy config, so shipping it costs nothing if the answer turns out to be "his
paths were fine".

Run from the repo root, against a vendor tree with 0055 not yet applied.
"""
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "configuration.c"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0055-visionos-heal-dead-container-dirs.patch"

ANCHOR = """   if (*settings->paths.directory_screenshot)
   {
      if (string_is_equal(settings->paths.directory_screenshot, "default"))
         *settings->paths.directory_screenshot = '\\0';
      else if (!path_is_directory(settings->paths.directory_screenshot))
      {
         RARCH_WARN("[Config] \\"screenshot_directory\\" is not an existing directory, ignoring...\\n");
         *settings->paths.directory_screenshot = '\\0';
      }
   }
"""

ADD = ANCHOR + """
#if TARGET_OS_VISION
   /* 0055: heal a system_directory / playlist_directory left pointing
    * into a DEAD per-install app container. iOS/visionOS rename the data
    * container on every install; the two settings above self-heal because
    * upstream existence-checks them, these two never did. Narrow on purpose —
    * only a path that IS a container path (the literal marker below) and does
    * NOT exist is touched, so a missing Files-provider or user-chosen folder is
    * left exactly as configured. See scripts/gen-patch-0055.py. */
   {
      const char * const ra_container_marker = "/Containers/Data/Application/";
      struct { char *path; const char *ident; const char *fallback; } ra_heal[2];
      int ra_i;

      ra_heal[0].path     = settings->paths.directory_system;
      ra_heal[0].ident    = "system_directory";
      ra_heal[0].fallback = g_defaults.dirs[DEFAULT_DIR_SYSTEM];
      ra_heal[1].path     = settings->paths.directory_playlist;
      ra_heal[1].ident    = "playlist_directory";
      ra_heal[1].fallback = g_defaults.dirs[DEFAULT_DIR_PLAYLIST];

      for (ra_i = 0; ra_i < 2; ra_i++)
      {
         char *ra_p = ra_heal[ra_i].path;
         if (!ra_p || !*ra_p)
            continue;
         if (string_is_equal(ra_p, "default"))
            continue;
         if (!strstr(ra_p, ra_container_marker))
            continue;
         if (path_is_directory(ra_p))
            continue;

         RARCH_WARN("[Config] \\"%s\\" points into a dead app container (%s), re-pointing...\\n",
               ra_heal[ra_i].ident, ra_p);
         {
            extern void RA_BeaconMark(const char *stage);
            char ra_msg[700];
            snprintf(ra_msg, sizeof(ra_msg), "config heal: %s '%s' is a dead container -> '%s'",
                  ra_heal[ra_i].ident, ra_p,
                  (ra_heal[ra_i].fallback && *ra_heal[ra_i].fallback)
                     ? ra_heal[ra_i].fallback : "(cleared)");
            RA_BeaconMark(ra_msg);
         }
         if (ra_heal[ra_i].fallback && *ra_heal[ra_i].fallback)
            configuration_set_string(settings, ra_p, ra_heal[ra_i].fallback);
         else
            *ra_p = '\\0';
      }
   }
#endif
"""

text = SRC.read_text()
if "ra_container_marker" in text:
    sys.exit("0055 already applied to vendor — reverse it out before regenerating")

n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")

new = text.replace(ANCHOR, ADD)

diff = difflib.unified_diff(
    text.splitlines(keepends=True),
    new.splitlines(keepends=True),
    fromfile=f"a/{REL}",
    tofile=f"b/{REL}",
    n=3,
)
OUT.write_text(f"diff --git a/{REL} b/{REL}\n" + "".join(diff))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p1", "--dry-run", "--force", "--fuzz=0",
     "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
