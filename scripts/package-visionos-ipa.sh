#!/bin/bash
# Package the SIGNED visionOS device build into an installable IPA (no hosting,
# no upload: it only writes a file).
#
#   scripts/package-visionos-ipa.sh [out.ipa]
#       default out: build-visionos/RetroArch-<CFBundleShortVersionString>-visionOS.ipa
#
# Env:
#   RA_APP        the .app (default: the xros build of scripts/build-visionos-app.sh)
#   RA_INFOSEED   optional dir holding info/*.info: replaces the stale core-info
#                 inside assets.zip (current libretro-core-info)
#   RA_DBSEED     optional dir holding database/rdb/*.rdb: bundled so content
#                 scanning works offline (libretro-database)
#   RA_IDENTITY   codesign identity for the re-sign (default: the app's own)
#   RA_PUBLIC=0   allow packaging a PERSONAL build (one with bundled profiles);
#                 by default only a public build (RABuildVariant=public, no .3dn,
#                 no index.bin) is packaged.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_SRC="${RA_APP:-$ROOT/build-visionos/DerivedData/Build/Products/Release-xros/RetroArch.app}"
STAGE="$ROOT/build-visionos/ipa-stage"

[[ -d "$APP_SRC" ]] || { echo "FATAL: no app at $APP_SRC — build first" >&2; exit 1; }

PLAT=$(vtool -show-build-version "$APP_SRC/RetroArch" 2>/dev/null | awk '/platform/{print $2}')
[[ "$PLAT" == "VISIONOS" ]] || { echo "FATAL: $PLAT is not a visionOS device build" >&2; exit 1; }
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SRC/Info.plist")
VARIANT="$(/usr/libexec/PlistBuddy -c 'Print :RABuildVariant' "$APP_SRC/Info.plist" 2>/dev/null || echo private)"
N3DN="$(find "$APP_SRC" -iname '*.3dn' | wc -l | tr -d ' ')"
NIDX="$(find "$APP_SRC" -name index.bin | wc -l | tr -d ' ')"
echo "=== source: $APP_SRC"
echo "  bundle $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_SRC/Info.plist") · v$VERSION · build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_SRC/Info.plist") · $VARIANT ($N3DN .3dn, $NIDX index.bin) · $(ls "$APP_SRC/Frameworks/" | grep -c libretro) cores"
if [[ "${RA_PUBLIC:-1}" != 0 ]]; then
  [[ "$VARIANT" == public ]] || { echo "FATAL: $APP_SRC is a $VARIANT build — rebuild with RA_PUBLIC=1 (or RA_PUBLIC=0 to package a personal build)" >&2; exit 1; }
  [[ "$N3DN" -eq 0 && "$NIDX" -eq 0 ]] || { echo "FATAL: public build carries 3dSen profiles/index.bin" >&2; exit 1; }
fi
codesign --verify --deep --strict "$APP_SRC" || { echo "FATAL: source app signature invalid" >&2; exit 1; }

OUT="${1:-$ROOT/build-visionos/RetroArch-$VERSION-visionOS.ipa}"
rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
cp -R "$APP_SRC" "$STAGE/Payload/RetroArch.app"
APP="$STAGE/Payload/RetroArch.app"
NEED_RESIGN=0

# The widget extension carries no NSExtensionPointIdentifier on visionOS, and the
# installer rejects the whole package over it ("Invalid placeholder attributes"),
# silently on device. It is inert on visionOS anyway.
if [[ -d "$APP/PlugIns" ]]; then
  echo "=== dropping $(ls "$APP/PlugIns" | wc -l | tr -d ' ') app extension(s) (they block a visionOS install)"
  rm -rf "$APP/PlugIns"; NEED_RESIGN=1
fi
# Current core-info: the bundled assets.zip ships 2018-2019 info files (wrong
# bsnes-hd name, thin MAME metadata). Overlay 0017 re-extracts assets.zip when
# CFBundleVersion changes, so an update picks this up.
if [[ -n "${RA_INFOSEED:-}" ]]; then
  [[ -d "$RA_INFOSEED/info" ]] || { echo "FATAL: RA_INFOSEED=$RA_INFOSEED has no info/" >&2; exit 1; }
  echo "=== refreshing $(ls "$RA_INFOSEED/info"/*.info | wc -l | tr -d ' ') core-info files in assets.zip"
  zip -qd "$APP/assets.zip" 'info/*' '__MACOSX/info/*' >/dev/null 2>&1 || true
  ( cd "$RA_INFOSEED" && zip -qr "$APP/assets.zip" info )
  NEED_RESIGN=1
fi
if [[ -n "${RA_DBSEED:-}" ]]; then
  [[ -d "$RA_DBSEED/database/rdb" ]] || { echo "FATAL: RA_DBSEED=$RA_DBSEED has no database/rdb/" >&2; exit 1; }
  echo "=== bundling $(ls "$RA_DBSEED/database/rdb"/*.rdb | wc -l | tr -d ' ') databases into assets.zip"
  ( cd "$RA_DBSEED" && zip -qr "$APP/assets.zip" database )
  NEED_RESIGN=1
fi
if [[ "$NEED_RESIGN" == 1 ]]; then
  IDENTITY="${RA_IDENTITY:-$(codesign -dvv "$APP_SRC" 2>&1 | sed -n '/^Authority=/{s/^Authority=//p;q;}' || true)}"
  [[ -n "$IDENTITY" ]] || { echo "FATAL: no signing identity (set RA_IDENTITY)" >&2; exit 1; }
  ENTS="$STAGE/ents.plist"
  codesign -d --entitlements "$ENTS" --xml "$APP" 2>/dev/null || true
  ENT_ARGS=(); [[ -s "$ENTS" ]] && ENT_ARGS=(--entitlements "$ENTS")
  codesign --force --sign "$IDENTITY" ${ENT_ARGS[@]+"${ENT_ARGS[@]}"} --generate-entitlement-der "$APP"
  codesign --verify --deep --strict "$APP" || { echo "FATAL: re-sign failed" >&2; exit 1; }
  echo "=== re-signed: $IDENTITY"
fi

mkdir -p "$(dirname "$OUT")"
( cd "$STAGE" && rm -f "$OUT" && zip -qry "$OUT" Payload )
# Read the version back out of the PACKAGED bundle, not the source.
GOT="$(unzip -p "$OUT" Payload/RetroArch.app/Info.plist | plutil -extract CFBundleShortVersionString raw -o - -)"
[[ "$GOT" == "$VERSION" ]] || { echo "FATAL: packaged version $GOT != $VERSION" >&2; exit 1; }
echo "=== packaged: $OUT ($(du -h "$OUT" | cut -f1), v$GOT, $VARIANT)"
