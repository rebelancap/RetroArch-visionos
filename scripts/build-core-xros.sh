#!/bin/bash
# Build the libretro cores from source for visionOS (xrOS).
# The buildbot has no xros slice,
# so visionOS cores are built here. Output dylibs are staged into
# pkg/apple/visionOS/modules/<core>_libretro_xros.dylib for make-frameworks.
#
# Usage: scripts/build-core-xros.sh [device|sim]   (default: device)
# Laws: toolchain vars as command-line args (beat makefile CC=),
# never env; -target beats stray -m*-version-min. Verify with vtool.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORES="$ROOT/vendor/cores"
# RA_MODULES_DIR redirects staging (e.g. simulator slices kept apart from the
# device modules make-frameworks wraps); default is the device modules dir.
MODULES="${RA_MODULES_DIR:-$ROOT/vendor/RetroArch/pkg/apple/visionOS/modules}"
LOGD="$ROOT/build-visionos/core-logs"
mkdir -p "$MODULES" "$LOGD"
# RA_CORES="mgba stella2014 ..." builds only the named cores (by vendor dir
# name); unset = all thirteen. The build commands themselves are unaffected.
want() { [ -z "${RA_CORES:-}" ] || [[ " $RA_CORES " == *" $1 "* ]]; }

MODE="${1:-device}"
if [ "$MODE" = "sim" ]; then
    XR=$(xcrun --sdk xrsimulator --show-sdk-path)
    TGT=arm64-apple-xros26.0-simulator
else
    XR=$(xcrun --sdk xros --show-sdk-path)
    TGT=arm64-apple-xros26.0
fi
CC="cc -arch arm64 -isysroot $XR -target $TGT"
CXX="c++ -arch arm64 -isysroot $XR -target $TGT"
J=$(sysctl -n hw.ncpu)
echo "=== xrOS core build ($MODE): $XR ==="

stage() { # <built-dylib> <staged-basename>
    [ -f "$1" ] || { echo "  FAIL: $1 not produced" >&2; return 1; }
    local plat; plat=$(vtool -show-build-version "$1" 2>/dev/null | awk '/platform/{print $2}')
    cp -f "$1" "$MODULES/$2"
    echo "  staged $2  ($plat, $(du -h "$1" | cut -f1))"
}

# --- snes9x (SNES) ------------------------------------------------------------
# LD must be the C++ driver: snes9x is C++ and the link pulls libc++/libc++abi
# (___cxa_guard_*, ___cxa_pure_virtual). LD="cc" leaves those unresolved on this SDK; c++ driver adds -lc++ implicitly.
if want snes9x; then
( cd "$CORES/snes9x/libretro" && make clean >/dev/null 2>&1
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" CC="$CC" CXX="$CXX" LD="$CXX" \
    > "$LOGD/snes9x.log" 2>&1 )
stage "$CORES/snes9x/libretro/snes9x_libretro_ios.dylib" "snes9x_libretro_xros.dylib"
fi

# --- mesen (NES) --------------------------------------------------------------
if want mesen; then
( cd "$CORES/mesen/libretro" && make clean >/dev/null 2>&1
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" CC="$CC" CXX="$CXX" LD="$CXX" \
    > "$LOGD/mesen.log" 2>&1 )
stage "$CORES/mesen/libretro/mesen_libretro_ios.dylib" "mesen_libretro_xros.dylib"
fi

# --- mame2003-plus (arcade) — needs -Dfdopen=fdopen (§1: 2013 zlib relic) -----
if want mame2003-plus; then
( cd "$CORES/mame2003-plus" && make clean >/dev/null 2>&1
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" \
    CC="$CC -Dfdopen=fdopen" CXX="$CXX -Dfdopen=fdopen" LD="$CC" \
    > "$LOGD/mame.log" 2>&1 )
stage "$CORES/mame2003-plus/mame2003_plus_libretro_ios.dylib" "mame2003_plus_libretro_xros.dylib"
fi

# --- bsnes-hd (SNES HD mode-7) — nall macos branch + compiler override (§2) ---
# -DBSNES_XROS_WIDESCREEN flips the compiled default of bsnes_mode7_wsMode from
# "Mode 7" to "all" for this slice only (overlay 0053), so SNES content is
# widescreen everywhere rather than only in Mode 7 scenes. The core already
# reports the widened 16:9 geometry, which the window aspect lock follows.
#
# -DBSNES_GCD_PARALLEL is THE HD Mode 7 performance lever (overlay 0056).
# Upstream parallelises PPU::Line::flush()'s scanline loop with OpenMP and
# defaults openmp=true; Apple ships no libomp and there is none for xros, and
# nall/GNUmakefile forces openmp=false the moment `compiler=` is overridden — so
# without this define every HD scanline renders on ONE core of the M2's eight.
# 0056 runs the same loop through dispatch_apply instead. Mac harness, Mode 7
# demo, retro_run avg: 8x 21.951 -> 3.310 ms, 10x 32.331 -> 4.449 ms, and six
# dumped frames byte-identical between the two builds.
if want bsnes-hd-beta; then
( cd "$CORES/bsnes-hd-beta/bsnes" && make -f GNUmakefile clean >/dev/null 2>&1 || true
  make -f GNUmakefile -j$J platform=macos target=libretro binary=library \
    local=false openmp=false \
    compiler="clang++ -target $TGT -isysroot $XR -DBSNES_XROS_WIDESCREEN -DBSNES_GCD_PARALLEL" \
    > "$LOGD/bsnes.log" 2>&1 )
stage "$CORES/bsnes-hd-beta/bsnes/out/bsnes_hd_beta_libretro.dylib" "bsnes_hd_beta_libretro_xros.dylib"
fi

# --- mupen64plus-next (N64) — GLES header shim + GL_LIB override (§3) ----------
# angrylion (software RDP) + cxd4 (LLE RSP) => no GPU API needed; GLideN64's GLES
# imports stay unresolved flat-namespace symbols, never selected at runtime.
SHIM="$ROOT/build-visionos/xros-shim"
if [ ! -d "$SHIM/OpenGLES" ]; then
    mkdir -p "$SHIM"
    cp -R "$(xcrun --sdk iphoneos --show-sdk-path)/System/Library/Frameworks/OpenGLES.framework/Headers" "$SHIM/OpenGLES"
    printf '#include <math.h>\n' > "$SHIM/fp.h"
fi
# -DMUPEN_SW_DEFAULT flips the compiled core-option defaults to angrylion (RDP) +
# cxd4 (RSP) for this xros slice only (overlay 0016), so N64 renders software with
# zero config on a fresh install; iOS keeps GLideN64. Needs HAVE_THR_AL + HAVE_LLE,
# which the ios-arm64 block already sets.
# -DMUPEN_FILL_WINDOW enables overlay 0052: crop the N64's VI blanking and fill
# the presented surface edge to edge, with the src/dst ratio preserved exactly
# (no anamorphic error). Port-only policy, hence the gate.
#
# ==> THE ONE-CHARACTER SWITCH <==
# -DMUPEN_FORCE_THREADED_RENDERER=N drives overlay 0043's force. 0 is the
# .16-.23 behaviour, byte for byte. 1 turns GLideN64's threaded GL replay ON
# (-39 % retro_run on the mac harness,; soaked clean and pixel-identical
# for 12 000 frames + 5 load/unload cycles).
#
# FLIPPED TO 1, as the SINGLE variable of that build: .26
# changes exactly two core dylibs — this one, and mesen for overlay 0061 (a
# logging/robustness change that cannot touch N64). Nothing else moved: same
# frontend binary, same ANGLE, same bsnes/snes9x/mame. So a device verdict of
# "smoother"/"same"/"worse" on N64 attributes cleanly to this switch. Revert is
# this one character; =0 is byte-for-byte the .16-.25 behaviour.
MUPEN_TR="-DMUPEN_FORCE_THREADED_RENDERER=1"
# 0052b: the extra uniform zoom that pushes the N64's blank native lines
# (SM64 draws ~8 black lines top and bottom of its 240) off the surface. 1.0f (or
# removing the define) restores the .23 picture; larger crops more.
MUPEN_ZOOM="-DMUPEN_FILL_WINDOW_ZOOM=1.06f"
MUPEN_DEFS="-DMUPEN_VK_DEFAULT -DMUPEN_SW_DEFAULT -DMUPEN_FILL_WINDOW $MUPEN_ZOOM $MUPEN_TR"
if want mupen64plus-next; then
( cd "$CORES/mupen64plus-next" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" \
    CC="$CC -I$SHIM -Dfdopen=fdopen $MUPEN_DEFS" CXX="$CXX -I$SHIM -Dfdopen=fdopen $MUPEN_DEFS" \
    GL_LIB="-undefined dynamic_lookup" \
    > "$LOGD/mupen.log" 2>&1 )
stage "$CORES/mupen64plus-next/mupen64plus_next_libretro_ios.dylib" "mupen64plus_next_libretro_xros.dylib"
fi

# ============================================================================
# eight software-rendered cores, interpreter-only, no JIT.
# Same laws as above: toolchain as make args, -target wins, vtool-verified.
# The *MINVER*/MINVERSION="" args drop each makefile's -miphoneos-version-min.
# ============================================================================

# --- Beetle VB (Virtual Boy) — plain C/C++, makefile ios-arm64 block ----------
if want mednafen-vb; then
( cd "$CORES/mednafen-vb" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" IPHONEMINVER="" CC="$CC" CXX="$CXX" \
    > "$LOGD/mednafen-vb.log" 2>&1 )
stage "$CORES/mednafen-vb/mednafen_vb_libretro_ios.dylib" "mednafen_vb_libretro_xros.dylib"
fi

# --- Genesis Plus GX (MD / Sega CD / SMS / GG) — no dynarec in this core ------
if want genesis-plus-gx; then
( cd "$CORES/genesis-plus-gx" && make -f Makefile.libretro clean >/dev/null 2>&1 || true
  make -f Makefile.libretro -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" CC="$CC" CXX="$CXX" \
    > "$LOGD/genesis-plus-gx.log" 2>&1 )
stage "$CORES/genesis-plus-gx/genesis_plus_gx_libretro_ios.dylib" "genesis_plus_gx_libretro_xros.dylib"
fi

# --- mGBA (GB / GBC / GBA) — CMake (buildbot's own CORE_ARGS), native visionOS -
# CMAKE_SYSTEM_NAME=visionOS selects the xros/xrsimulator sysroot; mGBA has no
# JIT. Out-of-tree build dir so the vendor tree stays pristine.
if want mgba; then
MGBA_BLD="$ROOT/build-visionos/mgba-$MODE"
if [ "$MODE" = "sim" ]; then MGBA_SYSROOT=xrsimulator; else MGBA_SYSROOT=xros; fi
( rm -rf "$MGBA_BLD" && mkdir -p "$MGBA_BLD" && cd "$MGBA_BLD"
  cmake "$CORES/mgba" -G "Unix Makefiles" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=$MGBA_SYSROOT \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DLIBMGBA_ONLY=ON -DBUILD_LIBRETRO=ON \
    > "$LOGD/mgba.log" 2>&1
  make -j$J mgba_libretro >> "$LOGD/mgba.log" 2>&1 )
stage "$MGBA_BLD/mgba_libretro.dylib" "mgba_libretro_xros.dylib"
fi

# --- PCSX-ReARMed (PS1) — DYNAREC=0 (interpreter), software GPU (gpu_neon) ----
# The makefile's ios-arm64 block already picks DYNAREC=0; passing it on the
# command line makes the no-JIT posture explicit and unoverridable.
if want pcsx-rearmed; then
( cd "$CORES/pcsx-rearmed" && make -f Makefile.libretro clean >/dev/null 2>&1 || true
  make -f Makefile.libretro -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" \
    DYNAREC=0 CC="$CC" CXX="$CXX" \
    > "$LOGD/pcsx-rearmed.log" 2>&1 )
stage "$CORES/pcsx-rearmed/pcsx_rearmed_libretro_ios.dylib" "pcsx_rearmed_libretro_xros.dylib"
fi

# --- melonDS (DS) — ios block sets no JIT_ARCH (no ARMJIT); software renderer --
if want melonds; then
( cd "$CORES/melonds" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" JIT_ARCH= CC="$CC" CXX="$CXX" \
    > "$LOGD/melonds.log" 2>&1 )
stage "$CORES/melonds/melonds_libretro_ios.dylib" "melonds_libretro_xros.dylib"
fi

# --- Beetle PCE Fast (PC Engine / TurboGrafx-16 / CD) -------------------------
# -Dfdopen=fdopen: its bundled zlib 1.2.11 zutil.h #defines fdopen away on
# __APPLE__, which breaks the SDK's _stdio.h (same relic as mame2003-plus).
if want mednafen-pce-fast; then
( cd "$CORES/mednafen-pce-fast" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" IPHONEMINVER="" \
    CC="$CC -Dfdopen=fdopen" CXX="$CXX -Dfdopen=fdopen" \
    > "$LOGD/mednafen-pce-fast.log" 2>&1 )
stage "$CORES/mednafen-pce-fast/mednafen_pce_fast_libretro_ios.dylib" "mednafen_pce_fast_libretro_xros.dylib"
fi

# --- Stella 2014 (Atari 2600) -------------------------------------------------
if want stella2014; then
( cd "$CORES/stella2014" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" CC="$CC" CXX="$CXX" \
    > "$LOGD/stella2014.log" 2>&1 )
stage "$CORES/stella2014/stella2014_libretro_ios.dylib" "stella2014_libretro_xros.dylib"
fi

# --- DOSBox Pure (DOS) — the ios block compiles with -DDISABLE_DYNAREC=1 ------
if want dosbox-pure; then
( cd "$CORES/dosbox-pure" && make clean >/dev/null 2>&1 || true
  make -j$J platform=ios-arm64 IOSSDK="$XR" MINVERSION="" CC="$CC" CXX="$CXX" \
    > "$LOGD/dosbox-pure.log" 2>&1 )
stage "$CORES/dosbox-pure/dosbox_pure_libretro_ios.dylib" "dosbox_pure_libretro_xros.dylib"
fi

echo "=== staged cores ==="
ls -la "$MODULES"/*.dylib | awk '{print $5, $9}'
