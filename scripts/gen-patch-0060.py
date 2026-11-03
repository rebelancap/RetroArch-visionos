#!/usr/bin/env python3
"""Generate overlay/patches/0060-cores-mesen-ra3d-scene-export.patch.

The read side of patch 0059's per-frame scene stream: three C entry points the
frontend reaches by `dlsym` on the loaded core, exactly the way 's
`mesen_ra3d_get_planes` is reached today.

  mesen_ra3d_set_scene_enabled(int on)
      Turn capture on.  It is OFF at power-on, and while it is off the core does
      no scene work at all — so an ordinary 2D session pays nothing for this
      interface existing.  A 3D consumer calls this once at startup and once
      more with 0 when it stops.

  mesen_ra3d_scene_supported(void)
      Presence check that does not require a running game.  A frontend can tell
      "this core has no scene stream" (dlsym fails) from "it has one but no
      frame has been published yet" (returns 1, get_scene returns 0).

  mesen_ra3d_get_scene(struct Ra3dScene *out)
      Fill `out` with the most recently published frame; 0 if none.  The
      pointers inside are owned by the core and stay valid until the frame
      after next — the same double-buffer contract the planes use.

Why dlsym and not a libretro environment call: identical reasoning.
The scene is a side channel to the visionOS shell, and routing it through
`retro_video_refresh` or a custom environment number would put core-specific
data into RetroArch's generic video path, where it would have to be threaded
through the frontend's frame pacing. `dlsym` keeps the ordinary 2D path — and
every other frontend that loads this core — byte-for-byte unchanged.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "vendor/cores/mesen"
REL = "Libretro/libretro.cpp"
OUT = ROOT / "overlay/patches/0060-cores-mesen-ra3d-scene-export.patch"

# Deliberately NOT placed next to mesen_ra3d_get_planes, which is the obvious
# home for it: that function and its trailing context belong to patch 0031's
# last hunk, and inserting there makes 0031 neither forward- nor reverse-
# appliable, which is exactly the failure apply-overlay.sh shouts about. The
# rule "patches must not edit inside each other's hunks" has teeth. This lands
# in front of retro_serialize_size instead, ~70 lines clear of any other hunk.
ANCHOR = """	RETRO_API size_t retro_serialize_size()
"""

REPL = """/* ---- RA3D scene stream (M1) ----------------------------------------------
 * mesen_ra3d_get_planes (above) says what the frame LOOKS like; this says what
 * is IN it: one entry per 8x8 cell on screen, carrying the cell's CHR tile (by index
 * into a per-frame atlas of raw 16-byte tiles), its screen position, its depth
 * class, its palette, its flips, and — for sprites — its OAM index, which is
 * the identity that lets a 3D renderer keep an object's geometry attached to
 * it as it moves.  See Core/PPU.h for the two structs and gen-patch-0059.py
 * for how they are captured.
 *
 * Capture is OFF until set_scene_enabled(1); a 2D session pays nothing. */
extern "C" void mesen_ra3d_set_scene_enabled(int enabled)
{
	if(!_console) return;
	PPU *ppu = _console->GetPpu();
	if(ppu) ppu->SetRA3DSceneEnabled(enabled != 0);
}

/* Lets a frontend distinguish "core has no scene stream" (dlsym fails) from
 * "it has one but has not published a frame yet" (this returns 1, get_scene
 * returns 0). Deliberately usable before a game is loaded. */
extern "C" int mesen_ra3d_scene_supported(void)
{
	return 1;
}

/* Fills *out with the most recently published frame; 0 if none has been.
 * The pointers inside belong to the core and are valid until the frame after
 * next — same double-buffer contract as the planes. */
extern "C" int mesen_ra3d_get_scene(Ra3dScene *out)
{
	if(!out || !_console) return 0;
	PPU *ppu = _console->GetPpu();
	if(!ppu) return 0;
	return ppu->GetRA3DScene(out) ? 1 : 0;
}

	RETRO_API size_t retro_serialize_size()
"""

src = CORE / REL
text = src.read_text()
n = text.count(ANCHOR)
if n != 1:
	sys.exit(f"anchor matched {n} times in {REL} (want 1)")

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
hunk_start = line_no - len(lead)
hunk = (f"@@ -{hunk_start},{len(lead)+len(old_lines)+len(rest)} "
        f"+{hunk_start},{len(lead)+len(new_lines)+len(rest)} @@\n"
        + "\n".join(body) + "\n")

OUT.write_text(f"diff --git a/cores/mesen/{REL} b/cores/mesen/{REL}\n"
               f"--- a/cores/mesen/{REL}\n"
               f"+++ b/cores/mesen/{REL}\n" + hunk)
print(f"wrote {OUT}")
subprocess.run(["patch", "-p3", "--dry-run", "-d", str(CORE), "-i", str(OUT)], check=True)
print("dry-run OK")
