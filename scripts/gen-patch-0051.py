#!/usr/bin/env python3
"""Generate overlay/patches/0051-cores-mupen-xros-force-hle-rsp-with-gliden64.patch.

The other half. 0050 makes GLideN64 render correctly even when it is
driven by an LLE RSP; this patch stops the visionOS build getting into that
mispairing in the first place.

Overlay 0016 compiles the xros slice with `-DMUPEN_SW_DEFAULT`, which flips the
compiled default of `mupen64plus-rsp-plugin` to **cxd4** — deliberately, to pair
with the *software* (angrylion) RDP, "parallel RSP is JIT-only, dead without a
debugger". But the shipped configuration runs the **GLideN64** RDP, and GLideN64
is an HLE graphics plugin: with cxd4 executing the ucode, GLideN64's own
`gSPViewport()`/`gSPProcessVertex()` HLE state is never populated, which is
exactly what produced the boxed picture (0050). Upstream already encodes the
mirror-image rule immediately above — "if we use angrylion with hle, we will
force parallel if available" — it simply never wrote the converse.

Two payoffs, both measured:

* correctness — GLideN64 gets the HLE display-list state it is written against;
* performance — mac harness, device config, same ROM/state: `retro_run` avg
  **4.017 ms with cxd4 vs 2.736 ms with hle** (own measurement), i.e.
  ~32 % of the core's per-frame CPU handed back on a device that needs it.

FORCED, not defaulted, for the reason 0043 documents: The tester's device persists
`rsp-plugin` in `Mupen64Plus-Next.opt`, so changing the compiled default is inert
there. Placed at the very end of the plugin-selection block — after upstream's
own `#ifdef IOS` "Parallel RSP without JIT" fallback, which can itself land on
cxd4 — so it catches every route to an LLE RSP, whatever the option file says.
Gated `#if defined(MUPEN_VK_DEFAULT)` so the iOS and macOS-harness builds are
byte-for-byte untouched.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/libretro/libretro.c"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0051-cores-mupen-xros-force-hle-rsp-with-gliden64.patch"

ANCHOR = """             log_cb(RETRO_LOG_INFO, "Selected Parallel RSP without JIT, falling back to GLideN64!\\n");
             plugin_connect_rsp_api(RSP_PLUGIN_HLE);
             plugin_connect_rdp_api(RDP_PLUGIN_GLIDEN64);
#endif
          }
       }
#endif
"""

ADDITION = """
#if defined(MUPEN_VK_DEFAULT)
       /* 0051 (visionOS only): GLideN64 is an HLE graphics plugin. Driven by an
        * LLE RSP (cxd4) its own display-list state is never filled in —
        * gSP.viewport stays {0,0,0,0} for the whole session — and
        * _needAdjustCoordinate() then crops every frame to the centre 75 % in
        * "16:9 adjusted" (0050 hardens GLideN64 against it too). The
        * xros slice defaults rsp-plugin to cxd4 (overlay 0016) to pair with the
        * *software* RDP, and that default is persisted in the device's
        * Mupen64Plus-Next.opt, so it has to be FORCED here rather than changed.
        * Upstream already encodes the mirror-image rule above (hle + angrylion
        * -> force an LLE RSP); this is the converse it never wrote. Also worth
        * 4.017 -> 2.736 ms of retro_run on the mac harness at the device's
        * settings. Runs last, after upstream's own JIT fallback, so it catches
        * every route to an LLE RSP. */
       if (current_rdp_type == RDP_PLUGIN_GLIDEN64 && current_rsp_type != RSP_PLUGIN_HLE)
       {
          log_cb(RETRO_LOG_INFO, "GLideN64 needs the HLE RSP; overriding the selected RSP plugin.\\n");
          plugin_connect_rsp_api(RSP_PLUGIN_HLE);
       }
#endif
"""

TRAIL = 2
text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "0051 (visionOS only)" in text:
    sys.exit("0051 already applied to vendor — reverse it out before regenerating")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1
anchor_lines = ANCHOR.rstrip("\n").split("\n")
add_lines = ADDITION.rstrip("\n").split("\n")
rest = text[start + len(ANCHOR):].split("\n")[:TRAIL]
body = [" " + l for l in anchor_lines]
body += ["+" + l if l else "+" for l in add_lines]
body += [" " + l if l else " " for l in rest]
old_count = len(anchor_lines) + len(rest)
new_count = old_count + len(add_lines)

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n"
    f"--- a/{REL}\n"
    f"+++ b/{REL}\n"
    f"@@ -{line_no},{old_count} +{line_no},{new_count} @@\n"
    + "\n".join(body) + "\n"
)
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mupen64plus-next"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
