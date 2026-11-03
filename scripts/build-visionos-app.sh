#!/bin/bash
# Build the native visionOS (xrOS) RetroArch device app. Cores must already be
# staged into pkg/apple/visionOS/modules/ (scripts/build-core-xros.sh) and the
# overlay applied (scripts/apply-overlay.sh). Output:
#   build-visionos/DerivedData/Build/Products/Release-xros/RetroArch.app
# then run scripts/package-visionos-ipa.sh to inject info+db, re-sign and
# package an installable IPA.
#
# CURRENT_PROJECT_VERSION is a MONOTONIC minute-stamp baked into CFBundleVersion.
# It's load-bearing: overlay 0017 makes assets.zip re-extract when CFBundleVersion
# changes, so every build must carry a higher number or updated info/databases
# won't reach an already-installed device. Minute resolution keeps it < uint32.
#
# Variants:
#   default         PUBLIC build (RA_PUBLIC=1, or --public): bundles NO .3dn and
#                   NO index.bin, adds Info.plist RABuildVariant=public, and
#                   fails if any .3dn / index.bin ended up in the .app (or any
#                   file byte-identical to one under $RA_PUBLIC_REF_DIRS).
#   RA_PUBLIC=0     PERSONAL build (or --private): bundles the 101 official 3dSen
#                   profiles YOU extracted from your own copy of 3dSen
#                   (scripts/3dsen-extract-profiles.py) from $RA3D_PROFILE_CORPUS,
#                   + index.bin, and fails unless all 101 are there. Never
#                   redistribute such a build.
#   RA_SDK=xrsimulator  simulator build of either variant: unsigned xcodebuild
#                   into build-visionos-sim/, widget appex dropped, framework
#                   binaries swapped for build-visionos-sim/modules-xrsim slices,
#                   ad-hoc signed. Never publishable (publish checks platform).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RA_PUBLIC="${RA_PUBLIC:-1}"
for a in "$@"; do
  case "$a" in
    --public) RA_PUBLIC=1 ;;
    --private) RA_PUBLIC=0 ;;
    *) echo "FATAL: unknown argument $a (only --public / --private)" >&2; exit 1 ;;
  esac
done
[[ "$RA_PUBLIC" == 0 || "$RA_PUBLIC" == 1 ]] || { echo "FATAL: RA_PUBLIC must be 0 or 1" >&2; exit 1; }
RA_SDK="${RA_SDK:-xros}"
case "$RA_SDK" in
  xros)        DD="$ROOT/build-visionos/DerivedData" ;;
  xrsimulator) DD="$ROOT/build-visionos-sim/DerivedData" ;;
  *) echo "FATAL: RA_SDK must be xros or xrsimulator" >&2; exit 1 ;;
esac
echo "=== variant: $([[ $RA_PUBLIC == 1 ]] && echo PUBLIC || echo private) · sdk $RA_SDK ==="
CPV="${CURRENT_PROJECT_VERSION:-$(date +%y%m%d%H%M)}"   # e.g. 2607181423

# --- marketing version ---------------------------------------------------------
# Pass MARKETING_VERSION (e.g. 1.23.0) for a release build. Otherwise dev builds
# get an auto-incremented FOURTH component (BASE.1, BASE.2, ...) recorded in
# OTA-VERSION: visionOS compares this string against the installed app to decide
# whether an over-the-air install replaces it, so a repeated version is a
# silent no-op install.
VERFILE="$ROOT/OTA-VERSION"
if [[ -n "${MARKETING_VERSION:-}" ]]; then
  MV="$MARKETING_VERSION"
else
  BASE="1.23.0"
  if [[ -f "$VERFILE" ]]; then
    PREV="$(cat "$VERFILE")"
    if [[ "$PREV" == "$BASE".* ]]; then MV="$BASE.$(( ${PREV##*.} + 1 ))"; else MV="$BASE.1"; fi
  else
    MV="$BASE.1"
  fi
  echo "$MV" > "$VERFILE"
fi
echo "=== marketing version: $MV (CFBundleShortVersionString) ==="

# --- visionOS Info.plist (the immersive space needs the scene lifecycle) ------
# openImmersiveSpace fails with a bare .error — before makeConfiguration is even
# called — unless UIApplicationSupportsMultipleScenes is true.  Rather than
# patch the shared pkg/apple/iOS/Info.plist (which would flip the *iOS* app onto
# a scene lifecycle it does not implement), derive a visionOS-only copy at build
# time from the same source of truth and point INFOPLIST_FILE at it on the
# command line, where it outranks the target's own setting.
SRC_PLIST="$ROOT/vendor/RetroArch/pkg/apple/iOS/Info.plist"
GEN_PLIST="$ROOT/build-visionos/Info-visionOS.plist"
mkdir -p "$(dirname "$GEN_PLIST")"
cp "$SRC_PLIST" "$GEN_PLIST"
/usr/libexec/PlistBuddy -c "Delete :UIApplicationSceneManifest" "$GEN_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
  -c "Add :UIApplicationSceneManifest dict" \
  -c "Add :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes bool true" \
  "$GEN_PLIST" >/dev/null
SCENES=$(/usr/libexec/PlistBuddy -c 'Print :UIApplicationSceneManifest:UIApplicationSupportsMultipleScenes' "$GEN_PLIST")
[[ "$SCENES" == "true" ]] || { echo "FATAL: scene manifest not applied to $GEN_PLIST" >&2; exit 1; }
echo "=== visionOS Info.plist: UIApplicationSupportsMultipleScenes=$SCENES"

# --- spatial light gun gates -----------------------------------------
# Two plist keys, both silent when missing:
#  1. GameController vends NOTHING for a PSVR2 Sense unless GCSupportedGameControllers
#     carries a SpatialGamepad profile — no error, no log line, just "no
#     controllers found".  Upstream's plist has only ExtendedGamepad /
#     DirectionalGamepad / MicroGamepad.
#  2. ARKit's accessory-tracking authorization needs a purpose string, or the
#     prompt cannot be shown.
# Both are asserted afterwards, the same way the scene manifest above is.
/usr/libexec/PlistBuddy \
  -c "Delete :NSAccessoryTrackingUsageDescription" "$GEN_PLIST" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy \
  -c "Add :NSAccessoryTrackingUsageDescription string RetroArch tracks your spatial controller so you can aim it at the game screen like a light gun." \
  "$GEN_PLIST" >/dev/null
if ! /usr/libexec/PlistBuddy -c "Print :GCSupportedGameControllers" "$GEN_PLIST" >/dev/null 2>&1; then
  /usr/libexec/PlistBuddy -c "Add :GCSupportedGameControllers array" "$GEN_PLIST" >/dev/null
fi
GC_N=$(/usr/libexec/PlistBuddy -c "Print :GCSupportedGameControllers" "$GEN_PLIST" | grep -c "ProfileName" || true)
/usr/libexec/PlistBuddy \
  -c "Add :GCSupportedGameControllers:$GC_N dict" \
  -c "Add :GCSupportedGameControllers:$GC_N:ProfileName string SpatialGamepad" \
  "$GEN_PLIST" >/dev/null
/usr/libexec/PlistBuddy -c "Print :GCSupportedGameControllers" "$GEN_PLIST" \
  | grep -q "SpatialGamepad" \
  || { echo "FATAL: SpatialGamepad missing from GCSupportedGameControllers in $GEN_PLIST" >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Print :NSAccessoryTrackingUsageDescription" "$GEN_PLIST" >/dev/null \
  || { echo "FATAL: NSAccessoryTrackingUsageDescription missing from $GEN_PLIST" >&2; exit 1; }
echo "=== visionOS Info.plist: SpatialGamepad + NSAccessoryTrackingUsageDescription OK"

# --- public variant mark ----------------------------------------------
# Only the public build carries the key; the app beacons `build: public|private`
# from it and prints `profiles: none bundled (public build)` instead of a
# missing-index fault. The private plist is untouched (no key).
if [[ "$RA_PUBLIC" == 1 ]]; then
  /usr/libexec/PlistBuddy -c "Add :RABuildVariant string public" "$GEN_PLIST" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :RABuildVariant' "$GEN_PLIST")" == public ]] \
    || { echo "FATAL: RABuildVariant not applied to $GEN_PLIST" >&2; exit 1; }
  echo "=== visionOS Info.plist: RABuildVariant=public"
fi

echo "=== native visionOS build — CFBundleVersion=$CPV ==="
rm -rf "$DD/Build/Products/Release-$RA_SDK/RetroArch.app"
cd "$ROOT/vendor/RetroArch/pkg/apple"
if [[ "$RA_SDK" == xros ]]; then
xcodebuild build \
  -project RetroArch_iOS13.xcodeproj -scheme "RetroArch iOS Release" -sdk xros \
  -derivedDataPath "$DD" \
  SDKROOT=xros "SUPPORTED_PLATFORMS=xros xrsimulator" XROS_DEPLOYMENT_TARGET=26.0 \
  TARGETED_DEVICE_FAMILY=7 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="${RA_TEAM:-57G8J46Z2T}" \
  IOS_BUNDLE_IDENTIFIER="${RA_BUNDLE_ID:-com.rebelancap.retroarch}" \
  INFOPLIST_FILE="$GEN_PLIST" \
  MARKETING_VERSION="$MV" \
  CURRENT_PROJECT_VERSION="$CPV"
else
xcodebuild build \
  -project RetroArch_iOS13.xcodeproj -scheme "RetroArch iOS Release" -sdk xrsimulator \
  -derivedDataPath "$DD" \
  SDKROOT=xrsimulator "SUPPORTED_PLATFORMS=xros xrsimulator" XROS_DEPLOYMENT_TARGET=26.0 \
  TARGETED_DEVICE_FAMILY=7 ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO \
  IOS_BUNDLE_IDENTIFIER="${RA_BUNDLE_ID:-com.rebelancap.retroarch}" \
  INFOPLIST_FILE="$GEN_PLIST" \
  MARKETING_VERSION="$MV" \
  CURRENT_PROJECT_VERSION="$CPV"
fi

APP="$DD/Build/Products/Release-$RA_SDK/RetroArch.app"
MODULES="$ROOT/vendor/RetroArch/pkg/apple/visionOS/modules"

# --- the in-hand Zapper model (both variants) ---------------------------------
# app/visionos/assets/zapper.mesh (Max Keeley's NES Zapper, CC BY 4.0, converted
# by scripts/convert-zapper-mesh.py) and its licence note go to <app>/gun-model/,
# where RAVisionGun.m loads the mesh (it falls back to a procedural stand-in, and
# says so in the beacon, if the file is missing). Copied after xcodebuild, so the
# bundle is re-sealed afterwards: by the simulator block, by the profile staging
# (private device build), or right here (public device build).
GM_SRC="$ROOT/app/visionos/assets"
for f in zapper.mesh LICENSE-zapper-model.md; do
  [[ -s "$GM_SRC/$f" ]] || { echo "FATAL: $GM_SRC/$f missing (scripts/convert-zapper-mesh.py)" >&2; exit 1; }
done
rm -rf "$APP/gun-model"
mkdir -p "$APP/gun-model"
cp "$GM_SRC/zapper.mesh" "$GM_SRC/LICENSE-zapper-model.md" "$APP/gun-model/"
cmp -s "$GM_SRC/zapper.mesh" "$APP/gun-model/zapper.mesh" || { echo "FATAL: gun-model copy failed" >&2; exit 1; }
echo "=== gun model: zapper.mesh ($(stat -f %z "$APP/gun-model/zapper.mesh") B) + licence -> gun-model/"
if [[ "$RA_PUBLIC" == 1 && "$RA_SDK" == xros ]]; then
  GM_ID="$(codesign -dvv "$APP" 2>&1 | sed -n '/^Authority=/{s/^Authority=//p;q;}' || true)"
  [[ -n "$GM_ID" ]] || { echo "FATAL: built app has no signing Authority — cannot re-seal after gun-model staging" >&2; exit 1; }
  GM_ENTS="$ROOT/build-visionos/ents-build.plist"
  rm -f "$GM_ENTS"
  codesign -d --entitlements "$GM_ENTS" --xml "$APP" 2>/dev/null || true
  GM_ARGS=()
  [[ -s "$GM_ENTS" ]] && GM_ARGS=(--entitlements "$GM_ENTS")
  codesign --force --sign "$GM_ID" ${GM_ARGS[@]+"${GM_ARGS[@]}"} --generate-entitlement-der "$APP"
  codesign --verify --deep --strict "$APP" || { echo "FATAL: re-sign after gun-model staging failed" >&2; exit 1; }
  echo "=== re-signed after gun-model staging: $GM_ID"
fi

# --- simulator: sim core slices, no widget, ad-hoc signature ------------------
# make-frameworks wrapped the DEVICE dylibs; the simulator needs the xrsimulator
# slices (build-core-xros.sh RA_MODULES_DIR=build-visionos-sim/modules-xrsim),
# and the widget .appex blocks a simulator install. The freshness gate below
# then checks the sim slices' UUIDs instead of the device ones.
if [[ "$RA_SDK" == xrsimulator ]]; then
  MODULES="$ROOT/build-visionos-sim/modules-xrsim"
  rm -rf "$APP/PlugIns"
  for dylib in "$MODULES"/*_libretro_xros.dylib; do
    [ -e "$dylib" ] || continue
    base="$(basename "$dylib" _libretro_xros.dylib)"
    fw="$APP/Frameworks/$(echo "$base" | tr '_' '.').libretro.framework"
    [ -d "$fw" ] || { echo "FATAL: no framework $fw for sim slice $dylib" >&2; exit 1; }
    cp "$dylib" "$fw/$(basename "$fw" .framework)"
    codesign -f -s - "$fw" >/dev/null 2>&1
  done
  codesign -f -s - "$APP" >/dev/null 2>&1
  echo "=== simulator: $(ls "$MODULES"/*_libretro_xros.dylib | wc -l | tr -d ' ') sim core slices swapped in, PlugIns dropped, ad-hoc signed"
fi

# --- RA_PUBLIC=0: bundle your own extracted profiles ---------------------------
# Matched to the loaded ROM by content at run time (RAVisionLayers.m). Fails the
# build if $RA3D_PROFILE_CORPUS is missing or not exactly 101 profiles. Adding
# resources after xcodebuild breaks the seal, so re-sign with the build's own
# identity and entitlements (package-visionos-ipa.sh re-signs again anyway).
# PUBLIC variant: nothing is staged, so nothing needs re-sealing; the
# strip gate below proves the .app carries none of it instead.
if [[ "$RA_PUBLIC" == 0 ]]; then
"$ROOT/scripts/stage-3dsen-profiles.sh" "$APP"
if [[ "$RA_SDK" == xros ]]; then
SIGN_ID="$(codesign -dvv "$APP" 2>&1 | sed -n '/^Authority=/{s/^Authority=//p;q;}' || true)"
[[ -n "$SIGN_ID" ]] || { echo "FATAL: built app has no signing Authority — cannot re-seal after profile staging" >&2; exit 1; }
ENTS="$ROOT/build-visionos/ents-build.plist"
rm -f "$ENTS"
codesign -d --entitlements "$ENTS" --xml "$APP" 2>/dev/null || true
ENT_ARGS=()
[[ -s "$ENTS" ]] && ENT_ARGS=(--entitlements "$ENTS")
codesign --force --sign "$SIGN_ID" ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} --generate-entitlement-der "$APP"
codesign --verify --deep --strict "$APP" || { echo "FATAL: re-sign after profile staging failed" >&2; exit 1; }
echo "=== re-signed after profile staging: $SIGN_ID (entitlements: ${#ENT_ARGS[@]})"
else
codesign -f -s - "$APP" >/dev/null 2>&1
echo "=== re-signed (ad-hoc, simulator) after profile staging"
fi
else
  # --- public strip gate: no 3dSen profiles, by name AND by content ----------
  #  1. no .3dn, no index.bin, no 3dsen-profiles/ anywhere in the bundle
  #     (assets.zip listing included);
  #  2. no file in the bundle is byte-identical to any file under the
  #     directories in $RA_PUBLIC_REF_DIRS (e.g. your extracted profiles).
  #     Files < 64 bytes are skipped (e.g. filters/.empty would match any empty
  #     file). Without RA_PUBLIC_REF_DIRS only check 1 runs, and says so.
  bad=0
  hits="$(find "$APP" \( -iname '*.3dn' -o -name 'index.bin' -o -name '3dsen-profiles' \) -print)"
  if [[ -n "$hits" ]]; then echo "$hits" | sed 's/^/  PUBLIC LEAK: /' >&2; bad=1; fi
  if [[ -f "$APP/assets.zip" ]]; then
    # list first, then grep: `unzip | grep -q` fails OPEN under pipefail
    # (grep exits on the first hit, unzip takes SIGPIPE, the pipeline is 141)
    zl="$(unzip -Z1 "$APP/assets.zip")"
    if grep -Eiq '\.3dn$|3dsen' <<<"$zl"; then
      echo "  PUBLIC LEAK: assets.zip lists 3dSen content" >&2; bad=1
    fi
  fi
  REFDIRS=()
  for d in ${RA_PUBLIC_REF_DIRS:-}; do [[ -d "$d" ]] && REFDIRS+=("$d"); done
  if [[ ${#REFDIRS[@]} -gt 0 ]]; then
    REFSUMS="$ROOT/build-visionos/public-ref-sha256.txt"
    find "${REFDIRS[@]}" -type f -size +63c -print0 | xargs -0 shasum -a 256 | awk '{print $1}' | sort -u > "$REFSUMS"
    APPSUMS="$(find "$APP" -type f -size +63c -print0 | xargs -0 shasum -a 256)"
    dup="$(echo "$APPSUMS" | awk 'NR==FNR{ref[$1]=1;next} ($1 in ref){print substr($0, 67)}' "$REFSUMS" -)"
    if [[ -n "$dup" ]]; then echo "$dup" | sed 's/^/  PUBLIC LEAK (same bytes as work\/3dsen-*): /' >&2; bad=1; fi
    echo "=== public strip gate: $(echo "$APPSUMS" | wc -l | tr -d ' ') bundle files vs $(wc -l < "$REFSUMS" | tr -d ' ') reference hashes"
  else
    echo "=== public strip gate: no RA_PUBLIC_REF_DIRS — name check only"
  fi
  [[ "$bad" -eq 0 ]] || { echo "FATAL: public build carries 3dSen profile content" >&2; exit 1; }
  echo "=== public strip gate: 0 .3dn, no index.bin, no 3dSen bytes — OK"
fi

# --- freshness gate: the built .app MUST carry the cores we just staged -------
# A build once looked like it had shipped a stale core (a new beacon printed
# nothing on device). It had not — but nothing in this pipeline actually
# PROVED that, and a whole device round was spent on the wrong theory.
# make-frameworks wraps each pkg/apple/visionOS/modules/*.dylib into a
# .framework, vtool-restamps it and code-signs it, so the bytes differ; LC_UUID
# survives both, which makes it an exact identity check. Fail loudly on a
# mismatch rather than shipping a build whose provenance is a guess.
uuid_of() { dwarfdump --uuid "$1" 2>/dev/null | awk '{print $2; exit}'; }
stale=0
for dylib in "$MODULES"/*_libretro_xros.dylib; do
  [ -e "$dylib" ] || continue
  base="$(basename "$dylib" _libretro_xros.dylib)"
  fw="$APP/Frameworks/$(echo "$base" | tr '_' '.').libretro.framework"
  bin="$fw/$(basename "$fw" .framework)"
  if [ ! -f "$bin" ]; then
    echo "  core $base: NO framework at $fw" >&2; stale=1; continue
  fi
  a="$(uuid_of "$dylib")"; b="$(uuid_of "$bin")"
  if [ -n "$a" ] && [ "$a" = "$b" ]; then
    echo "  core $base: fresh (uuid $a)"
  else
    echo "  core $base: STALE — staged uuid $a != bundled uuid $b" >&2; stale=1
  fi
done
[ "$stale" -eq 0 ] || { echo "FATAL: the built .app does not carry the staged cores — rebuild/clean and retry" >&2; exit 1; }

echo "=== built: $(vtool -show-build-version "$APP/RetroArch" | awk '/platform/{print $2}') · $([[ $RA_PUBLIC == 1 ]] && echo PUBLIC || echo private) · $(find "$APP" -iname '*.3dn' | wc -l | tr -d ' ') .3dn · v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist") build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist") · $(ls "$APP/Frameworks" | grep -c libretro) cores ==="
