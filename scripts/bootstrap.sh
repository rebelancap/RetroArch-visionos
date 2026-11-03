#!/bin/bash
# Clean checkout -> buildable vendor tree. Idempotent. The upstream pin lives HERE.
#
# RetroArch is vendored pristine and pinned by commit. Cores are separate repos
# vendored under vendor/cores/<name>, each pinned. Local changes to any of them
# live ONLY in overlay/patches/ and are applied by scripts/apply-overlay.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- RetroArch frontend ------------------------------------------------------
RA_PIN="154e920b82c3b92c53bd53964317423276916923"  # master, 2026-07-16
RA_REPO="https://github.com/libretro/RetroArch.git"
RA_VENDOR="$ROOT/vendor/RetroArch"

if [[ ! -d "$RA_VENDOR/.git" ]]; then
    # Shallow is fine for a pinned vendor; deepen only if a bump needs history.
    git clone "$RA_REPO" "$RA_VENDOR"
fi
git -C "$RA_VENDOR" fetch origin "$RA_PIN" 2>/dev/null || git -C "$RA_VENDOR" fetch origin
git -C "$RA_VENDOR" checkout --detach "$RA_PIN" 2>/dev/null || {
    echo "note: pin $RA_PIN not in shallow clone; leaving current HEAD" >&2
}
echo "RetroArch pinned: $(git -C "$RA_VENDOR" rev-parse HEAD)"

# --- MoltenVK 1.4.1 (adds the xros slice RetroArch's bundled 1.2.8 lacks) --------
# Needed for the Vulkan video driver on visionOS (ParaLLEl-RDP N64, later flycast).
# Binary asset — can't be an overlay patch; fetched + verified here and installed
# over the vendored 1.2.8 xcframework. Idempotent: skips once the xros slice is in.
MVK_VER="1.4.1"
MVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v${MVK_VER}/MoltenVK-all.tar"
MVK_SHA="2c498bf8c98b88ba1e84c1f153403d4c1a8490c122d9e2a3df238b25d4e10557"
MVK_DEST="$RA_VENDOR/pkg/apple/Frameworks/MoltenVK.xcframework"
if [[ -d "$MVK_DEST/xros-arm64" ]]; then
    echo "MoltenVK: xros slice present (>=${MVK_VER})"
else
    echo "MoltenVK: installing ${MVK_VER} (xros slice)"
    MVK_CACHE="$ROOT/work/moltenvk"; mkdir -p "$MVK_CACHE"
    if [[ ! -f "$MVK_CACHE/MoltenVK-all.tar" ]] \
       || [[ "$(shasum -a 256 "$MVK_CACHE/MoltenVK-all.tar" | cut -d' ' -f1)" != "$MVK_SHA" ]]; then
        curl -fL --retry 3 -o "$MVK_CACHE/MoltenVK-all.tar" "$MVK_URL"
    fi
    got="$(shasum -a 256 "$MVK_CACHE/MoltenVK-all.tar" | cut -d' ' -f1)"
    [[ "$got" == "$MVK_SHA" ]] || { echo "FATAL: MoltenVK sha256 mismatch ($got)" >&2; exit 1; }
    ( cd "$MVK_CACHE" && tar -xf MoltenVK-all.tar "MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework" )
    rm -rf "$MVK_DEST"
    cp -R "$MVK_CACHE/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework" "$MVK_DEST"
    [[ -d "$MVK_DEST/xros-arm64" ]] || { echo "FATAL: MoltenVK xros slice missing after install" >&2; exit 1; }
    echo "MoltenVK: installed $(ls "$MVK_DEST" | grep -c xros) xros slices"
fi

# --- ANGLE (GLES3-over-Metal) for visionOS — GLideN64 N64 path -----------
# Binary build output (libANGLE-shared.dylib + libEGLGLES_shim.dylib), not an
# overlay patch. scripts/build-angle-xros.sh sparse-checks-out WebKit's ANGLE and
# builds it — HEAVY (~250 MB fetch + build). Idempotent: skips once staged. See
# its header.
ANGLE_DEST="$RA_VENDOR/pkg/apple/Frameworks/angle-xros"
if [[ -f "$ANGLE_DEST/libANGLE-shared.dylib" ]]; then
    echo "ANGLE: present (angle-xros staged)"
else
    echo "ANGLE: building for xros (heavy — WebKit ANGLE sparse checkout + build)"
    "$ROOT/scripts/build-angle-xros.sh"
    [[ -f "$ANGLE_DEST/libANGLE-shared.dylib" ]] || { echo "FATAL: ANGLE dylib missing after build" >&2; exit 1; }
fi

# --- Cores (built from source for the sim + visionOS slices) ------------------
# Device iOS slices come prebuilt from buildbot.libretro.com; these sources are
# for the slices the buildbot does NOT ship (iphonesimulator, xros, xrsimulator).
# repo|pin|dir   (pin left blank = track default branch until a build is proven,
# then freeze the resolved commit here — one core, one pin)
CORES=(
  # Pins frozen once each core's xros slice built + linked. scripts/build-core-xros.sh
  # cross-builds the sim + xros/xrsimulator slices the buildbot doesn't ship.
  "https://github.com/libretro/snes9x.git|185488cd83aaf274752a742c94d45561cbecb7af|snes9x"
  "https://github.com/libretro/Mesen.git|0102910c39ad1a62bc3f784466f3f67ca9eae335|mesen"          # NES
  "https://github.com/libretro/mame2003-plus-libretro.git|2cca4441706b952c2eaf8264713b53fd5452e0bd|mame2003-plus"
  "https://github.com/DerKoun/bsnes-hd.git|fc26b25ea236f0f877f0265d2a2c37dfd93dfde9|bsnes-hd-beta"  # SNES HD mode-7
  "https://github.com/libretro/mupen64plus-libretro-nx.git|98c1b0d877542b01314b3b04272282ba223b65b3|mupen64plus-next"  # N64 (angrylion+cxd4 on xros)
  # eight software-rendered cores, interpreter-only (no JIT), pinned at
  # the tips that built + smoke-tested for xros/xrsimulator on 2026-10-31.
  "https://github.com/libretro/beetle-vb-libretro.git|d5ae54c8e23b573a3b34e888b2d48a588027e92c|mednafen-vb"        # Virtual Boy
  "https://github.com/libretro/Genesis-Plus-GX.git|f27655b592ef43f317272d79883bcaa10d3ac8ad|genesis-plus-gx"        # MD/SCD/SMS/GG
  "https://github.com/libretro/mgba.git|7a12d6d4b9acb14c0ae62c9166b6a2f3d08007f6|mgba"                              # GB/GBC/GBA
  "https://github.com/libretro/pcsx_rearmed.git|7b0e8f8fadfbce3d170d195b9d9eecaabfa08c8e|pcsx-rearmed"              # PS1 (DRC_DISABLE)
  "https://github.com/libretro/melonDS.git|66b5d2634cd0a79030562811e6e05f5532f800ba|melonds"                         # DS (no ARMJIT)
  "https://github.com/libretro/beetle-pce-fast-libretro.git|2de1ce1c3f237b161c126c54ba407990bb86d1e9|mednafen-pce-fast"  # PCE/TG16
  "https://github.com/libretro/stella2014-libretro.git|7d1361e407e63f29e52892655069e5fb4096e691|stella2014"          # Atari 2600
  "https://github.com/libretro/dosbox-pure.git|cdaea10ce8cac231bc341ca05d4c5e4e5fe0fbd5|dosbox-pure"                 # DOS (DISABLE_DYNAREC)
  # flycast: deferred — SH4 JIT-gated on iOS/visionOS 26, Vulkan render path (step 2)
  # "https://github.com/libretro/flycast.git||flycast"
)
for spec in "${CORES[@]}"; do
    IFS='|' read -r repo pin dir <<< "$spec"
    dest="$ROOT/vendor/cores/$dir"
    [[ -d "$dest/.git" ]] || git clone "$repo" "$dest"
    if [[ -n "$pin" ]]; then
        git -C "$dest" fetch origin "$pin" 2>/dev/null || true
        git -C "$dest" checkout --detach "$pin"
    fi
    echo "core $dir pinned: $(git -C "$dest" rev-parse HEAD)"
done

echo "bootstrap done."
