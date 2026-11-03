#!/usr/bin/env python3
"""Generate overlay/patches/0056-cores-bsnes-hd-gcd-parallel-lines.patch.

THE bsnes-hd HD-Mode-7 PERFORMANCE LEVER (item 1).

Measured problem (the tester, Vision Pro): HD Mode 7 scale 2x and 4x hold
60 fps, 8x drops to ~35 fps. Reproduced on the mac harness with an open-source
Mode 7 demo ROM (gyuque/snes-m7 "MOON BASE"), M4 Pro, retro_run average:

    scale   1x     2x     4x     8x
    ms     1.685  2.873  7.174  21.951      (45 fps at 8x on a machine FASTER
                                             than the headset's M2)

Where the time goes: `PPU::Line::flush()` (sfc/ppu-fast/line.cpp) renders every
scanline of the accumulated batch, and at hdScale N each scanline is N times
wider and rendered N times over — the work is O(N^2) in the scale, which is
exactly the 1.7 -> 2.9 -> 7.2 -> 22.0 curve above.

Upstream ALREADY parallelises that loop — `#pragma omp parallel for` — and
bsnes-hd's GNUmakefile defaults `openmp := true`. Our slices cannot use it:
Apple's clang ships no libomp, there is no xros build of libomp to link or
bundle, and nall/GNUmakefile itself forces `openmp = false` when the compiler is
overridden (nall/GNUmakefile:78). Both scripts/build-core-xros.sh and
 therefore pass `openmp=false`, so the
shipped core renders every HD scanline on ONE core of an eight-core M2 while the
other seven idle.

THE PATCH: keep the OpenMP path byte-for-byte for every other platform, and add
a Grand Central Dispatch path for ours — `dispatch_apply` over the same loop,
under the same `count >= 8` guard upstream uses, gated on -DBSNES_GCD_PARALLEL.
libdispatch is in the visionOS SDK, needs nothing bundled, and sizes the work to
the machine at runtime (DISPATCH_APPLY_AUTO) rather than to a compile-time
thread count.

Safety: the loop body is unchanged and is moved verbatim into a capture-less
lambda that both paths call, so the OpenMP build compiles the same statements it
compiled before. The iterations were already required to be independent — that
is what upstream's own `#pragma omp parallel for` asserts — each iteration
touching only `ppu.lines[Line::start + y]` and its own slice of the output
buffer. Verified here by pixel-comparing dumped frames base vs parallel.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/bsnes-hd-beta/bsnes/sfc/ppu-fast/line.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0056-cores-bsnes-hd-gcd-parallel-lines.patch"

# --- hunk 1: the gated include -------------------------------------------------
A1 = """#include <emulator/hdtoolkit.hpp>
"""
R1 = """#include <emulator/hdtoolkit.hpp>
#if defined(BSNES_GCD_PARALLEL)
  /* 0056: Apple has no libomp for xros, so the scanline loop below runs through
   * libdispatch instead of OpenMP on this port's slices. */
  #include <dispatch/dispatch.h>
#endif
"""

# --- hunk 2: the loop ----------------------------------------------------------
A2 = """    if(ppu.hdScale() > 1) cacheMode7HD();
    #pragma omp parallel for if(Line::count >= 8)
    for(uint y = 0; y < Line::count; y++) {
      if(ppu.deinterlace()) {
        if(!ppu.interlace()) {
          //some games enable interlacing in 240p mode, just force these to even fields
          ppu.lines[Line::start + y].render(0);
        } else {
          //for actual interlaced frames, render both fields every farme for 480i -> 480p
          ppu.lines[Line::start + y].render(0);
          ppu.lines[Line::start + y].render(1);
        }
      } else {
        //standard 240p (progressive) and 480i (interlaced) rendering
        ppu.lines[Line::start + y].render(ppu.field());
      }
    }
"""

R2 = """    if(ppu.hdScale() > 1) cacheMode7HD();
    /* 0056: the loop body, verbatim, hoisted so the OpenMP path and the GCD
     * path render through identical statements. */
    auto renderOne = [](uint y) {
      if(ppu.deinterlace()) {
        if(!ppu.interlace()) {
          //some games enable interlacing in 240p mode, just force these to even fields
          ppu.lines[Line::start + y].render(0);
        } else {
          //for actual interlaced frames, render both fields every farme for 480i -> 480p
          ppu.lines[Line::start + y].render(0);
          ppu.lines[Line::start + y].render(1);
        }
      } else {
        //standard 240p (progressive) and 480i (interlaced) rendering
        ppu.lines[Line::start + y].render(ppu.field());
      }
    };
#if defined(BSNES_GCD_PARALLEL)
    /* Same guard as upstream's `if(Line::count >= 8)`: mid-frame flushes caused
     * by a register write are usually a handful of lines, and are not worth a
     * dispatch. DISPATCH_APPLY_AUTO sizes the width to the machine at runtime;
     * dispatch_apply runs on the calling thread plus workers and returns only
     * when every iteration is done, so flush() keeps its exact semantics. */
    if(Line::count >= 8) {
      dispatch_apply(Line::count, DISPATCH_APPLY_AUTO, ^(size_t y) {
        renderOne((uint)y);
      });
    } else {
      for(uint y = 0; y < Line::count; y++) renderOne(y);
    }
#else
    #pragma omp parallel for if(Line::count >= 8)
    for(uint y = 0; y < Line::count; y++) renderOne(y);
#endif
"""

text = SRC.read_text()
if "BSNES_GCD_PARALLEL" in text:
    sys.exit("0056 already applied to vendor — reverse it out before regenerating")

hunks = []
for anchor, repl in ((A1, R1), (A2, R2)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"anchor matched {n} times in {SRC} (want 1):\n{anchor[:80]}")
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    old_lines = anchor.rstrip("\n").split("\n")
    new_lines = repl.rstrip("\n").split("\n")
    LEAD = TRAIL = 3
    lead = text[:start].rstrip("\n").split("\n")[-LEAD:] if start else []
    rest = text[start + len(anchor):].split("\n")[:TRAIL]

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
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/bsnes-hd-beta"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
