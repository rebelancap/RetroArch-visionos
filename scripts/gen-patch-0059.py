#!/usr/bin/env python3
"""Generate overlay/patches/0059-cores-mesen-ra3d-scene-stream.patch.

Turn the Mesen core into a **per-frame 3D scene
source**, not just a frame of pixels.

WHY THIS EXISTS

 `mesen_ra3d_get_planes` splits the finished picture into four depth
planes.  That is enough for layer parallax and it is what ships today, but it
carries no *identity*: the shell sees coloured pixels, never "this 8x8 cell is
CHR tile 0x1A3 of palette 2, and it is the same object it was last frame".
Every step beyond parallax — 3dSen-style per-object geometry, profile-free
heuristic extrusion, shape tracking — needs the identity, and no libretro
environment call exposes it (research §3.3: SET_MEMORY_MAPS is CPU space only,
and this fork has no debugger).

WHAT IT ADDS

A second, independent read-side interface publishing a compacted **per-tile
scene table** plus a **per-frame CHR atlas**:

    Ra3dSceneTile { x, y, chr, layer, palette, flags, oam,
                    scroll_x, scroll_y, nametable, chr_addr }
    Ra3dScene     { frame, tile_count, atlas_count, tiles, atlas,
                    palette_ram, rgb_palette }

`atlas` is `atlas_count * 16` **raw CHR bytes** — bitplane 0 then bitplane 1,
exactly as they sit in the pattern table.  That is deliberate: it is the same
16 bytes a 3dSen `.3dn` profile stores as its tile-match key (as two
little-endian u64s under a rotate-xor), so a profile-driven renderer matches by
comparing the atlas entry directly, with no hashing and no ambiguity.  The same
table serves the profile-free heuristic mode, which needs only layer + palette
+ adjacency.  One stream, both consumers.

HOW THE TILES ARE CAPTURED

*Background* — inside `PPU::DrawPixel()`, which already runs the RA3D split and
already knows which `TileInfo` is responsible for the pixel it is drawing.  A
background tile cell begins at every screen x where `(x + fineX) % 8 == 0`, so
the capture costs one mask-and-compare at those pixels and nothing anywhere
else.  Capturing from the *rendering* path rather than from a nametable walk is
what makes mid-frame scroll changes come out right for free: a status-bar split
simply produces a row whose origin-y differs from the row above it.

That is the row rule: a tile's origin row is `scanline - OffsetY` (OffsetY is
the PPU's fine-Y).  A row is captured the first scanline its origin differs
from the row captured before it — once per tile cell in the steady state, and
again immediately after any scroll write that moves the row boundary.  No hook
into $2005/$2006 is needed and none is added.

*Sprites* — from OAM at frame end, not from the per-scanline `_spriteTiles`.
OAM gives what the scanline evaluation throws away: the **OAM index** (stable
object identity across frames, listed as the one gap in research §3.2), the
true sprite X and Y, and sprites the 8-per-scanline limit dropped.  A dropped
sprite is invisible in 2D but is a real object in a 3D scene, so reporting it
is correct rather than generous.  8x16 sprites emit two entries, halves swapped
under vertical flip exactly as `LoadSprite()` does it.

COST WHEN NOBODY IS LOOKING

The whole capture is behind one `bool` that starts **false** and is set only by
`mesen_ra3d_set_scene_enabled()` (patch 0060).  With it clear the added work is
a single predictable branch inside `DrawPixel()` and one at frame end; nothing
is allocated, nothing is published, `_ra3dSceneReadIdx` stays -1.

SCOPE / KNOWN LIMITS (documented, not accidental)

* `HdPpu` overrides `DrawPixel()` and `SendFrame()` and is **not** hooked here,
  so the scene stream is empty while an HD pack is loaded.  Patch 0057 owns
  those two overrides; adding a call inside its hunks is what the overlay rules
  forbid, and HD packs and 3D mode are mutually exclusive in any case.  If the
  two ever need to coexist, hoist 0057's blocks into `PPU` and add the call
  there.
* The CHR atlas is keyed on the bank-resolved absolute CHR address.  A CHR-RAM
  game that rewrites the same absolute address mid-frame would alias to the
  first content seen that frame.  No commercial game is known to do it; the
  atlas is rebuilt every frame, so the window is one frame wide.
* `mesen_ra3d_get_planes` is untouched and keeps working exactly as before —
  0057's guarantee. The two interfaces share no state beyond the frame counter.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "vendor/cores/mesen"
OUT = ROOT / "overlay/patches/0059-cores-mesen-ra3d-scene-stream.patch"

EDITS = []   # (relpath-under-cores/mesen, [(anchor, replacement), ...])

# ---------------------------------------------------------------------------
# Core/PPU.h
# ---------------------------------------------------------------------------

PPU_H = []

# --- 1. the public ABI structs, in front of the class ----------------------
PPU_H.append((
	"""	SpriteDMA = 0x4014,
};

class PPU : public IMemoryHandler, public Snapshotable
""",
	"""	SpriteDMA = 0x4014,
};

/* --- RA3D scene stream (M1) -------------------------------------------------
 * One entry per 8x8 cell that is on screen this frame: what tile it is, where
 * it is, which depth class it belongs to, and the scroll context it was
 * captured under.  Read through mesen_ra3d_get_scene(); see gen-patch-0059.py
 * for the capture rules. Plain C layout - the frontend reads it through dlsym
 * across a C ABI, so no vtable, no std:: members, no padding surprises. */
struct Ra3dSceneTile
{
	int16_t  X;          /* screen x of the cell's top-left corner; negative    */
	int16_t  Y;          /* when the cell is clipped off the left or top edge   */
	uint16_t Chr;        /* index into this frame's CHR atlas                   */
	uint8_t  Layer;      /* 0 background, 1 sprite behind BG, 2 sprite in front */
	uint8_t  Palette;    /* 0-3 background palette, 4-7 sprite palette          */
	uint8_t  Flags;      /* bit0 flip X, bit1 flip Y, bit2 lower half of 8x16   */
	uint8_t  Oam;        /* OAM index for a sprite, 0xFF for a background tile  */
	int16_t  ScrollX;    /* fine X scroll in effect when the cell was captured  */
	int16_t  ScrollY;    /* fine Y scroll ditto                                 */
	uint16_t Nametable;  /* loopy `v`: nametable select + coarse X/Y            */
	int32_t  ChrAddr;    /* bank-resolved absolute CHR address of the tile      */
};

struct Ra3dScene
{
	uint32_t FrameNumber;
	uint16_t TileCount;
	uint16_t AtlasCount;
	const Ra3dSceneTile *Tiles;
	const uint8_t *Atlas;        /* AtlasCount * 16 raw CHR bytes, plane0|plane1 */
	const uint8_t *PaletteRam;   /* 32 bytes, this frame's palette RAM           */
	const uint32_t *RgbPalette;  /* NES palette index -> ARGB, 512 entries       */
};

class PPU : public IMemoryHandler, public Snapshotable
"""))

# --- 2. member state, right after the existing RA3D plane state ------------
PPU_H.append((
	"""		bool _corruptOamRow[32];
""",
	"""		bool _corruptOamRow[32];

		/* --- RA3D scene stream (M1) -------------------------------------------
		 * Per-frame tile table + CHR atlas, double buffered and published the
		 * same way the planes are.  All of it is inert until the frontend calls
		 * mesen_ra3d_set_scene_enabled(1): _ra3dSceneEnabled gates the single
		 * branch this adds to DrawPixel(). */
		static constexpr int RA3D_SCENE_MAX_TILES = 2048;
		static constexpr int32_t RA3D_SCENE_NO_ROW = -100000;
		static constexpr int RA3D_SCENE_MAX_ATLAS = 1024;
		bool     _ra3dSceneEnabled;
		bool     _ra3dSceneRowActive;   /* capturing the row we are scanning?   */
		int32_t  _ra3dSceneRowY;        /* origin-y of that row; NO_ROW = none yet */
		uint16_t _ra3dSceneTileCount;
		uint16_t _ra3dSceneAtlasCount;
		Ra3dSceneTile _ra3dSceneTiles[RA3D_SCENE_MAX_TILES];
		uint8_t  _ra3dSceneAtlas[RA3D_SCENE_MAX_ATLAS * 16];
		int32_t  _ra3dSceneAtlasAddr[RA3D_SCENE_MAX_ATLAS];
		Ra3dSceneTile _ra3dScenePubTiles[2][RA3D_SCENE_MAX_TILES];
		uint8_t  _ra3dScenePubAtlas[2][RA3D_SCENE_MAX_ATLAS * 16];
		uint8_t  _ra3dScenePubPalette[2][0x20];
		uint16_t _ra3dScenePubTileCount[2];
		uint16_t _ra3dScenePubAtlasCount[2];
		uint32_t _ra3dScenePubFrame[2];
		std::atomic<int> _ra3dSceneReadIdx { -1 };

		uint16_t Ra3dSceneAtlasIndex(int32_t absAddr);
		void Ra3dSceneCaptureBgTile(const TileInfo &tile, int32_t x, int32_t y);
		void Ra3dSceneCaptureSprites();
		void Ra3dScenePublish();
"""))

# --- 3. the public accessors, next to the plane ones ----------------------
PPU_H.append((
	"""		uint8_t ReadPaletteRAM(uint16_t addr);
""",
	"""		uint8_t ReadPaletteRAM(uint16_t addr);

		/* RA3D scene stream (M1).  Off by default: capture costs nothing until
		 * a consumer asks for it, and asking is what a 3D mode does at startup. */
		void SetRA3DSceneEnabled(bool enabled) { _ra3dSceneEnabled = enabled; }
		bool GetRA3DSceneEnabled() { return _ra3dSceneEnabled; }
		bool GetRA3DScene(Ra3dScene *out);
"""))

EDITS.append(("Core/PPU.h", PPU_H))

# ---------------------------------------------------------------------------
# Core/PPU.cpp
# ---------------------------------------------------------------------------

PPU_CPP = []

# --- 1. capture hook inside DrawPixel -------------------------------------
PPU_CPP.append((
	"""	}
}

uint16_t PPU::GetCurrentBgColor()
""",
	"""	}

	/* RA3D scene stream: record the background tile CELL this pixel starts, if
	 * it starts one.  A cell begins wherever (x + fineX) is a multiple of 8:
	 * the pixel at x shows bit (fineX + x) of the shift-register stream, so
	 * that test is exact for every fine-X value, including the partial cell at
	 * the left edge.  All of it is behind _ra3dSceneEnabled, which is false
	 * unless a 3D consumer turned it on.
	 *
	 * Appended after the drawing branches rather than inside them so that this
	 * patch touches no line belonging to overlay 0031's hunks - editing inside
	 * another patch's hunk is what makes apply-overlay.sh unable to tell
	 * "applied" from "appliable". */
	if(_ra3dSceneEnabled && IsRenderingEnabled()) {
		uint8_t fineX = _state.XScroll;
		int32_t x = (int32_t)_cycle - 1;
		const TileInfo &tile = ((fineX + (((uint32_t)x) & 0x07)) < 8) ? _previousTile : _currentTile;
		if(x == 0) {
			/* The first pixel of a scanline decides whether this scanline is
			 * the top row of a band of cells.  A tile's origin row is
			 * scanline - fineY, so it changes exactly once per 8 scanlines
			 * while the scroll holds still, and immediately after any write
			 * that moves the row boundary - which is what makes status-bar
			 * splits and raster scroll come out as new rows rather than as
			 * torn ones. */
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
}

uint16_t PPU::GetCurrentBgColor()
"""))

# --- 2. the capture + publish implementations, in front of SendFrame ------
PPU_CPP.append((
	"""void PPU::SendFrame()
""",
	"""/* RA3D scene stream (M1) ---------------------------------------------------- */

/* Intern one 8x8 tile into this frame's CHR atlas and return its index.  The
 * atlas is what makes the stream self-contained: the consumer never has to
 * reach back into the mapper to know what a tile looks like, and the 16 bytes
 * it holds ARE the 3dSen tile-match key.
 * Keyed on the bank-resolved absolute address, so the same tile fetched from
 * two nametable cells interns once - a screen is typically 200-400 distinct
 * tiles out of 960 cells. Linear scan: n is small and this runs once per cell,
 * not per pixel. */
uint16_t PPU::Ra3dSceneAtlasIndex(int32_t absAddr)
{
	for(uint16_t i = 0; i < _ra3dSceneAtlasCount; i++) {
		if(_ra3dSceneAtlasAddr[i] == absAddr) {
			return i;
		}
	}
	if(_ra3dSceneAtlasCount >= RA3D_SCENE_MAX_ATLAS) {
		return 0;
	}
	uint16_t idx = _ra3dSceneAtlasCount++;
	_ra3dSceneAtlasAddr[idx] = absAddr;
	uint8_t *dst = _ra3dSceneAtlas + idx * 16;
	if(absAddr < 0) {
		memset(dst, 0, 16);   /* no CHR mapped here; report an empty tile */
	} else {
		/* CopyChrTile is the same call HdPpu uses to snapshot a tile bitmap
		 * (Core/HdPpu.cpp:70,118). It reads CHR ROM/RAM directly at the
		 * ABSOLUTE address, so the bytes cannot disagree with the address they
		 * were interned under - and it has no side effects on mappers that
		 * latch a bank on PPU pattern fetches (MMC2/MMC4), which a read through
		 * the PPU address space risks. */
		_console->GetMapper()->CopyChrTile((uint32_t)absAddr, dst);
	}
	return idx;
}

void PPU::Ra3dSceneCaptureBgTile(const TileInfo &tile, int32_t x, int32_t y)
{
	if(_ra3dSceneTileCount >= RA3D_SCENE_MAX_TILES) {
		return;
	}
	/* AbsoluteTileAddr points at the tile ROW being fetched, not at the tile;
	 * mask to the 16-byte tile base exactly as HdPpu does. */
	int32_t absBase = tile.AbsoluteTileAddr < 0 ? -1 : (tile.AbsoluteTileAddr & ~0x0F);
	Ra3dSceneTile &out = _ra3dSceneTiles[_ra3dSceneTileCount++];
	out.X = (int16_t)x;
	out.Y = (int16_t)y;
	out.Chr = Ra3dSceneAtlasIndex(absBase);
	out.Layer = 0;
	out.Palette = (uint8_t)((tile.PaletteOffset >> 2) & 0x03);
	out.Flags = 0;                /* background tiles are never flipped */
	out.Oam = 0xFF;
	out.ScrollX = (int16_t)_state.XScroll;
	out.ScrollY = (int16_t)tile.OffsetY;
	out.Nametable = (uint16_t)(_state.VideoRamAddr & 0x0FFF);
	out.ChrAddr = absBase;
}

/* Sprites come from OAM at frame end rather than from the per-scanline
 * evaluation, which is what gives the stream three things the 2D path throws
 * away: the OAM index (a stable object identity across frames), the true X/Y
 * of the sprite as an object, and sprites the 8-per-scanline limit dropped -
 * invisible in 2D, but real objects in a 3D scene. */
void PPU::Ra3dSceneCaptureSprites()
{
	BaseMapper *mapper = _console->GetMapper();
	bool large = _flags.LargeSprites;
	for(int i = 0; i < 64; i++) {
		uint8_t spriteY = _spriteRAM[i * 4];
		if(spriteY >= 240) {
			continue;   /* parked off-screen; the standard way to hide a sprite */
		}
		uint8_t tileIndex = _spriteRAM[i * 4 + 1];
		uint8_t attributes = _spriteRAM[i * 4 + 2];
		uint8_t spriteX = _spriteRAM[i * 4 + 3];
		bool hFlip = (attributes & 0x40) != 0;
		bool vFlip = (attributes & 0x80) != 0;
		int rows = large ? 2 : 1;
		for(int r = 0; r < rows; r++) {
			if(_ra3dSceneTileCount >= RA3D_SCENE_MAX_TILES) {
				return;
			}
			uint16_t base;
			if(large) {
				/* Bit 0 of the index selects the pattern table for 8x16; under
				 * vertical flip the two halves swap, matching LoadSprite(). */
				int half = vFlip ? (1 - r) : r;
				base = (uint16_t)((((tileIndex & 0x01) ? 0x1000 : 0x0000) |
				                   ((tileIndex & ~0x01) << 4)) + half * 16);
			} else {
				base = (uint16_t)((tileIndex << 4) | _flags.SpritePatternAddr);
			}
			Ra3dSceneTile &out = _ra3dSceneTiles[_ra3dSceneTileCount++];
			out.X = (int16_t)spriteX;
			/* OAM Y is one less than the scanline the sprite is drawn on. */
			out.Y = (int16_t)((int32_t)spriteY + 1 + r * 8);
			int32_t absBase = mapper->ToAbsoluteChrAddress(base);
			if(absBase >= 0) absBase &= ~0x0F;
			out.Chr = Ra3dSceneAtlasIndex(absBase);
			out.Layer = (attributes & 0x20) ? 1 : 2;   /* behind BG : in front */
			out.Palette = (uint8_t)(4 + (attributes & 0x03));
			out.Flags = (uint8_t)((hFlip ? 1 : 0) | (vFlip ? 2 : 0) | (r ? 4 : 0));
			out.Oam = (uint8_t)i;
			out.ScrollX = 0;
			out.ScrollY = 0;
			out.Nametable = 0;
			out.ChrAddr = absBase;
		}
	}
}

/* Publish into the half the reader is not holding, then release the index -
 * identical discipline to the depth planes, so a consumer can only ever see a
 * whole frame's scene. */
void PPU::Ra3dScenePublish()
{
	int write = (_ra3dSceneReadIdx.load(std::memory_order_relaxed) == 0) ? 1 : 0;
	uint16_t tiles = _ra3dSceneTileCount;
	uint16_t atlas = _ra3dSceneAtlasCount;
	memcpy(_ra3dScenePubTiles[write], _ra3dSceneTiles, tiles * sizeof(Ra3dSceneTile));
	memcpy(_ra3dScenePubAtlas[write], _ra3dSceneAtlas, (size_t)atlas * 16);
	memcpy(_ra3dScenePubPalette[write], _paletteRAM, 0x20);
	_ra3dScenePubTileCount[write] = tiles;
	_ra3dScenePubAtlasCount[write] = atlas;
	_ra3dScenePubFrame[write] = _ra3dFrame.load(std::memory_order_relaxed);
	_ra3dSceneReadIdx.store(write, std::memory_order_release);

	/* Next frame starts empty; the row rule needs a sentinel that no real
	 * origin row can equal, or scanline 0 of the new frame would be skipped
	 * whenever it happens to land on the same row as the last frame's. */
	_ra3dSceneTileCount = 0;
	_ra3dSceneAtlasCount = 0;
	_ra3dSceneRowY = RA3D_SCENE_NO_ROW;
	_ra3dSceneRowActive = false;
}

bool PPU::GetRA3DScene(Ra3dScene *out)
{
	int idx = _ra3dSceneReadIdx.load(std::memory_order_acquire);
	if(!out || idx < 0) {
		return false;
	}
	out->FrameNumber = _ra3dScenePubFrame[idx];
	out->TileCount = _ra3dScenePubTileCount[idx];
	out->AtlasCount = _ra3dScenePubAtlasCount[idx];
	out->Tiles = _ra3dScenePubTiles[idx];
	out->Atlas = _ra3dScenePubAtlas[idx];
	out->PaletteRam = _ra3dScenePubPalette[idx];
	out->RgbPalette = _settings->GetRgbPalette();
	return true;
}

void PPU::SendFrame()
"""))

# --- 3. run the sprite pass + publish, right after the planes are published -
PPU_CPP.append((
	"""#endif
}
""",
	"""#endif

	/* Scene stream: the background half accumulated across the scanlines, the
	 * sprite half is read out of OAM here, and the whole frame is published
	 * together - after the depth planes, so both carry the same frame number. */
	if(_ra3dSceneEnabled) {
		Ra3dSceneCaptureSprites();
		Ra3dScenePublish();
	}
}
"""))

# --- 4. initialise the new state at construction ---------------------------
PPU_CPP.append((
	"""	SetNesModel(NesModel::NTSC);

	Reset();
}
""",
	"""	SetNesModel(NesModel::NTSC);

	/* RA3D scene stream starts off and empty.  RA3D_SCENE_NO_ROW is a row
	 * origin no real tile can have (rows run -7..239), so the first scanline of
	 * the first frame always counts as a new row. */
	_ra3dSceneEnabled = false;
	_ra3dSceneRowActive = false;
	_ra3dSceneRowY = RA3D_SCENE_NO_ROW;
	_ra3dSceneTileCount = 0;
	_ra3dSceneAtlasCount = 0;

	Reset();
}
"""))

EDITS.append(("Core/PPU.cpp", PPU_CPP))


# ---------------------------------------------------------------------------
def build(rel, pairs):
	src = CORE / rel
	text = src.read_text()
	hunks = []
	# patch(1) requires hunks in file order; the edit list is written in reading
	# order (what each change is about), so sort before emitting.
	pairs = sorted(pairs, key=lambda p: text.index(p[0]) if text.count(p[0]) == 1 else 0)
	for anchor, repl in pairs:
		n = text.count(anchor)
		if n != 1:
			sys.exit(f"anchor matched {n} times in {rel} (want 1):\n{anchor[:120]}")
		start = text.index(anchor)
		line_no = text[:start].count("\n") + 1
		old_lines = anchor.rstrip("\n").split("\n")
		new_lines = repl.rstrip("\n").split("\n")
		LEAD = TRAIL = 3
		lead = text[:start].split("\n")[:-1][-LEAD:] if start else []
		tail = text[start + len(anchor):]
		# An anchor that does not end at a line break leaves the rest of its own
		# line in front of the trailing context; dropping it is what keeps the
		# context lines aligned with the file (a phantom blank line here makes
		# patch(1) reject the hunk).
		if not anchor.endswith("\n"):
			tail = tail.split("\n", 1)[1] if "\n" in tail else ""
		rest = tail.split("\n")[:TRAIL]
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
	return (f"diff --git a/cores/mesen/{rel} b/cores/mesen/{rel}\n"
	        f"--- a/cores/mesen/{rel}\n"
	        f"+++ b/cores/mesen/{rel}\n" + "".join(hunks))


out = "".join(build(rel, pairs) for rel, pairs in EDITS)
OUT.write_text(out)
print(f"wrote {OUT}")

subprocess.run(["patch", "-p3", "--dry-run", "-d", str(CORE), "-i", str(OUT)], check=True)
print("dry-run OK")
