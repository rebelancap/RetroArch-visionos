#!/usr/bin/env python3
"""Generate overlay/patches/0065-cores-mesen-hdppu-ra3d-scene.patch.

0057 ALL OVER AGAIN, ONE FEATURE LATER.

Overlay 0057 fixed the depth planes for the HD-pack case: `Console::Initialize()`
swaps `PPU` for **`HdPpu`** whenever a pack is loaded, `HdPpu` overrides both
`DrawPixel()` and `SendFrame()`, and 0031's plane capture/publish lived in
exactly those two methods — so with a pack active the planes were never written.

Overlays 0059/0060 then put the **3dSen scene stream** in the same two methods
(`PPU::DrawPixel()` captures one entry per background cell, `PPU::SendFrame()`
reads the sprites out of OAM and publishes the frame) and inherited the same
hole. With an HD pack loaded:

  * no background cell is ever captured,
  * `Ra3dScenePublish()` is never called, so `_ra3dSceneReadIdx` stays -1,
  * `mesen_ra3d_get_scene()` returns 0 forever, and
  * the visionOS shell prints `SHAPE MODE ON` and then `0 instances` for the
    rest of the session.

Super Mario Bros. is the one game the tester has both a `.3dn` profile AND an HD
pack for, which is why it was the one game where 3D mode did nothing but sit
there —.

THE PATCH: the same two blocks `PPU` has, in `HdPpu`'s overrides.

  * Hunk 1 goes at the TOP of `HdPpu::DrawPixel()`, not the bottom, because
    0057's hunk 1 already owns the middle of that function and a patch may not
    edit inside another patch's hunk. Position is behaviourally irrelevant:
    the block reads `_cycle`, `_scanline`, `_state.XScroll` and the tile
    registers, none of which `DrawPixel()` itself changes.
  * Hunk 2 goes at the TOP of `HdPpu::SendFrame()` for the same reason — 0057's
    hunk 2 owns its tail. The one visible consequence is that the scene's
    published frame number is taken BEFORE 0057's `_ra3dFrame.fetch_add()`
    rather than after, so an HD-pack session's scene frame numbers trail the
    plane frame numbers by one. Nothing compares the two: the shell only asks
    "did the scene number change since I last built?".

`HdPpu` is a `PPU` subclass in one object, so every member and both helpers are
reachable directly; nothing new is declared.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mesen/Core/HdPpu.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0065-cores-mesen-hdppu-ra3d-scene.patch"

# --- hunk 1: capture background cells, as PPU::DrawPixel() does ---------------
A1 = """	uint16_t bufferOffset = (_scanline << 8) + _cycle - 1;
	uint16_t &pixel = _currentOutputBuffer[bufferOffset];
	_lastSprite = nullptr;
"""
R1 = """	uint16_t bufferOffset = (_scanline << 8) + _cycle - 1;
	uint16_t &pixel = _currentOutputBuffer[bufferOffset];
	_lastSprite = nullptr;

	/* 0065: RA3D scene stream — the block PPU::DrawPixel() carries (overlay
	 * 0059).  This override would otherwise skip it entirely, so with an HD
	 * pack loaded the 3dSen shape mode saw an empty scene forever. */
	if(_ra3dSceneEnabled && IsRenderingEnabled()) {
		uint8_t fineX = _state.XScroll;
		int32_t x = (int32_t)_cycle - 1;
		const TileInfo &tile = ((fineX + (((uint32_t)x) & 0x07)) < 8) ? _previousTile : _currentTile;
		if(x == 0) {
			int32_t originY = _scanline - (int32_t)tile.OffsetY;
			_ra3dSceneRowActive = (originY != _ra3dSceneRowY);
			if(_ra3dSceneRowActive) {
				_ra3dSceneRowY = originY;
				Ra3dSceneCaptureBgTile(tile, -(int32_t)fineX, originY);
			}
		} else if(_ra3dSceneRowActive && ((fineX + (uint32_t)x) & 0x07) == 0) {
			Ra3dSceneCaptureBgTile(tile, x, _scanline - (int32_t)tile.OffsetY);
		}
	}
"""

# --- hunk 2: read out the sprites and publish, as PPU::SendFrame() does -------
A2 = """	_info->FrameNumber = _frameCount;
	_info->WatchedAddressValues.clear();
"""
R2 = """	/* 0065: RA3D scene stream — the sprite read-out and publish from
	 * PPU::SendFrame() (overlay 0059), which this override skips.  At the top
	 * rather than the bottom because 0057's hunk owns the tail of this
	 * function; see gen-patch-0065.py for why that is behaviourally free. */
	if(_ra3dSceneEnabled) {
		Ra3dSceneCaptureSprites();
		Ra3dScenePublish();
	}

	_info->FrameNumber = _frameCount;
	_info->WatchedAddressValues.clear();
"""

text = SRC.read_text()
if "0065" in text or "_ra3dSceneEnabled" in text.split("void HdPpu::")[1]:
    sys.exit("0065 already applied to vendor — reverse it out before regenerating")
if "0057" not in text:
    sys.exit("overlay 0057 must be applied to vendor first (0065 anchors around it)")

hunks = []
for anchor, repl in ((A1, R1), (A2, R2)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"anchor matched {n} times in {SRC} (want 1):\n{anchor[:90]}")
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    old_lines = anchor.rstrip("\n").split("\n")
    new_lines = repl.rstrip("\n").split("\n")
    LEAD = TRAIL = 2
    lead = text[:start].split("\n")[:-1][-LEAD:] if start else []
    rest = text[start + len(anchor):].split("\n")[:TRAIL]
    while rest and rest[-1] == "":
        rest.pop()

    body = [" " + l if l else " " for l in lead]
    body += ["-" + l if l else "-" for l in old_lines]
    body += ["+" + l if l else "+" for l in new_lines]
    body += [" " + l if l else " " for l in rest]
    old_count = len(lead) + len(old_lines) + len(rest)
    new_count = len(lead) + len(new_lines) + len(rest)
    hunk_start = line_no - len(lead)
    hunks.append(f"@@ -{hunk_start},{old_count} +{hunk_start},{new_count} @@\n"
                 + "\n".join(body) + "\n")

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n"
    f"--- a/{REL}\n"
    f"+++ b/{REL}\n"
    + "".join(hunks)
)
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mesen"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
