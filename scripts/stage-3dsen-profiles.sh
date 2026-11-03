#!/bin/bash
# Stage the 101 official 3dSen profiles YOU extracted (scripts/3dsen-extract-
# profiles.py, from your own copy of 3dSen) into a PERSONAL RetroArch.app.
#
#   RA3D_PROFILE_CORPUS=<dir of .3dn> stage-3dsen-profiles.sh <RetroArch.app>
#
# Copies $RA3D_PROFILE_CORPUS/*.3dn into <app>/3dsen-profiles/ and writes
# <app>/3dsen-profiles/index.bin (each profile's tile signature, built with the
# shipped parser by scripts/ra3d-profile-index.c) for ROM-content matching in
# RAVisionLayers.m.
#
# LICENCE POSTURE: the profiles are Geod's proprietary content. A build that
# carries them is for the owner of that 3dSen copy only: never commit them,
# never redistribute the IPA. This script fails loudly if the corpus is
# missing or does not hold exactly 101 profiles, rather than shipping a build
# that silently lost them.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?usage: stage-3dsen-profiles.sh <RetroArch.app>}"
CORPUS="${RA3D_PROFILE_CORPUS:?set RA3D_PROFILE_CORPUS to your extracted .3dn directory}"
WANT=101

[[ -d "$APP" ]] || { echo "FATAL: no app at $APP" >&2; exit 1; }
if [[ ! -d "$CORPUS" ]]; then
  echo "FATAL: 3dSen profile corpus missing at $CORPUS" >&2
  echo "       extract it with scripts/3dsen-extract-profiles.py" >&2
  exit 1
fi
shopt -s nullglob
files=("$CORPUS"/*.3dn)
if [[ ${#files[@]} -ne $WANT ]]; then
  echo "FATAL: $CORPUS holds ${#files[@]} .3dn files, want exactly $WANT (the official 3dSenVR v2 set)" >&2
  exit 1
fi

TOOL="$ROOT/build-visionos/ra3d-profile-index"
mkdir -p "$(dirname "$TOOL")"
cc -std=gnu99 -O2 -Wall -Wno-unused-parameter -Wno-unused-function \
   -I"$ROOT/app/visionos" -o "$TOOL" "$ROOT/scripts/ra3d-profile-index.c"

DST="$APP/3dsen-profiles"
rm -rf "$DST"
mkdir -p "$DST"
cp "${files[@]}" "$DST/"
"$TOOL" build "$DST/index.bin" "$DST"/*.3dn
n=$(ls "$DST"/*.3dn | wc -l | tr -d ' ')
[[ "$n" -eq $WANT && -s "$DST/index.bin" ]] \
  || { echo "FATAL: staged $n profiles / index missing in $DST" >&2; exit 1; }
echo "=== 3dSen profiles: $n bundled + index.bin ($(du -sh "$DST" | cut -f1)) in $DST"
