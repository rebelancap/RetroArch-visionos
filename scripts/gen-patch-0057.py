#!/usr/bin/env python3
"""Generate overlay/patches/0057-cores-mesen-hdppu-ra3d-planes.patch.

THE BUG THIS CLOSES BEFORE IT CAN BE SEEN.

Overlay 0031 gave Mesen the RA3D depth-plane split: `PPU::DrawPixel()`
fills `_ra3dLayer[0..3]` alongside the ordinary output pixel, and
`PPU::SendFrame()` converts them to ARGB and publishes them for the visionOS
shell to read through `mesen_ra3d_get_planes`.

Mesen does not use `PPU` when an HD pack is loaded. `Console::Initialize()`
swaps in **`HdPpu`**, which **overrides both of those methods** — and neither
override knows anything about RA3D:

  * `HdPpu::DrawPixel()` (Core/HdPpu.cpp) writes the output pixel and the HD
    pack's per-pixel tile info, and never touches `_ra3dLayer`.
  * `HdPpu::SendFrame()` (Core/HdPpu.cpp) calls `UpdateFrameSync()` directly and
    never runs 0031's publish block.

So with an HD pack active the planes are not merely wrong, they are **never
written at all**: `_ra3dReadIdx` stays at its initial -1 (nothing published
ever) or, if a pack is loaded after a non-HD game in the same process, freezes
on the last plain-PPU frame. The 3D mode would show a frozen or empty picture.

Nobody has hit this because nobody has had a working HD pack — which is exactly
what the rest of this round is about. It is therefore fixed in the same
build that makes packs load, not after.

THE PATCH: give `HdPpu`'s two overrides the same two RA3D blocks the base class
has, verbatim in behaviour. HdPpu is a `PPU` subclass in the same object, so it
reaches `_ra3dLayer` / `_ra3dPublished` / `_ra3dSprPixel` / `_ra3dSprInFront` /
`GetBackgroundPixelColor()` directly; `GetPixelColor()` — which HdPpu already
calls — is what sets `_ra3dSprPixel`, so the sprite half needs no new work.

The plane values are the RAW `_paletteRAM` entries, matching `PPU::DrawPixel()`
rather than HdPpu's own `pixel`, which has `_paletteRamMask` and
`_intensifyColorBits` folded in per pixel. That keeps the planes identical
between the HD and non-HD paths: in the base path grayscale/emphasis are applied
by `UpdateGrayscaleAndIntensifyBits()` to `_currentOutputBuffer` only and the
planes never see them either.

Deliberately duplicated rather than refactored into a shared helper: 0031 has no
generator in this tree (it predates the convention), so factoring the blocks out
would mean hand-editing an existing patch's hunks — which the overlay rules
forbid. Two blocks in one new file, touching no other patch, is the cheaper
correctness. If 0031 is ever regenerated, hoist both into `PPU` and shrink this
patch to two calls.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mesen/Core/HdPpu.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0057-cores-mesen-hdppu-ra3d-planes.patch"

# --- hunk 1: capture the planes while drawing ---------------------------------
A1 = """		uint32_t color = GetPixelColor();
		pixel = (_paletteRAM[color & 0x03 ? color : 0] & _paletteRamMask) | _intensifyColorBits;
"""
R1 = """		/* 0057: RA3D — same capture PPU::DrawPixel() does. GetPixelColor()
		 * below is what sets _ra3dSprPixel/_ra3dSprInFront, so it has to be
		 * cleared first, exactly as in the base class. */
		_ra3dSprPixel = RA3D_TRANSPARENT;
		uint32_t color = GetPixelColor();
		pixel = (_paletteRAM[color & 0x03 ? color : 0] & _paletteRamMask) | _intensifyColorBits;

		{
			uint32_t ra3dBg = GetBackgroundPixelColor();
			/* Colour 0 is TRANSPARENT on the NES: the backdrop shows there, and
			 * so does any behind-priority sprite. */
			_ra3dLayer[0][bufferOffset] = (ra3dBg & 0x03) ? _paletteRAM[ra3dBg] : RA3D_TRANSPARENT;
			_ra3dLayer[1][bufferOffset] = RA3D_TRANSPARENT;
			_ra3dLayer[2][bufferOffset] = RA3D_TRANSPARENT;
			_ra3dLayer[3][bufferOffset] = _paletteRAM[0];
			if(_ra3dSprPixel != RA3D_TRANSPARENT && _settings->GetSpritesEnabled()) {
				_ra3dLayer[_ra3dSprInFront ? 1 : 2][bufferOffset] = _paletteRAM[_ra3dSprPixel & 0x03 ? _ra3dSprPixel : 0];
			}
		}
"""

# --- hunk 2: publish them, as PPU::SendFrame() does ---------------------------
A2 = """	_console->GetVideoDecoder()->UpdateFrameSync(_currentOutputBuffer, _info);
}
"""
R2 = """	/* 0057: RA3D — the publish block from PPU::SendFrame(), which this override
	 * would otherwise skip entirely, leaving the depth planes frozen (or never
	 * written at all) for the whole time an HD pack is loaded. Written into the
	 * half the reader is not holding, then the index is released. */
	{
		uint32_t *ra3dPal = _settings->GetRgbPalette();
		int ra3dWrite = (_ra3dReadIdx.load(std::memory_order_relaxed) == 0) ? 1 : 0;
		for(int plane = 0; plane < RA3D_PLANES; plane++) {
			const uint16_t *src = _ra3dLayer[plane];
			uint32_t *dst = _ra3dPublished[ra3dWrite][plane];
			for(int i = 0; i < 256*240; i++) {
				uint16_t v = src[i];
				dst[i] = (v == RA3D_TRANSPARENT) ? 0u : (ra3dPal[v & 0x1FF] | 0xFF000000u);
			}
		}
		_ra3dFrame.fetch_add(1, std::memory_order_relaxed);
		_ra3dReadIdx.store(ra3dWrite, std::memory_order_release);
	}

	_console->GetVideoDecoder()->UpdateFrameSync(_currentOutputBuffer, _info);
}
"""

text = SRC.read_text()
if "0057" in text or "_ra3dLayer" in text:
    sys.exit("0057 already applied to vendor — reverse it out before regenerating")

hunks = []
for anchor, repl in ((A1, R1), (A2, R2)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"anchor matched {n} times in {SRC} (want 1):\n{anchor[:90]}")
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    old_lines = anchor.rstrip("\n").split("\n")
    new_lines = repl.rstrip("\n").split("\n")
    LEAD = TRAIL = 3
    # NB: do NOT rstrip() here — an anchor preceded by a blank line (hunk 1 is)
    # would silently lose that line from the context and the hunk would not apply.
    lead = text[:start].split("\n")[:-1][-LEAD:] if start else []
    rest = text[start + len(anchor):].split("\n")[:TRAIL]
    # Hunk 2's anchor ends the file; a phantom trailing "" would emit a context
    # line past EOF and make patch(1) warn ("No such line N in input file").
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
