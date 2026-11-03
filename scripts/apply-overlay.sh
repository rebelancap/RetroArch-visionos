#!/bin/bash
# Apply the overlay patch series to vendor/RetroArch (and vendor/cores/* when a
# patch path is prefixed cores/<name>/...). Idempotent and loud: a patch that is
# neither applied nor cleanly appliable fails the build.
#
# Patch file naming: NNNN-<target>-<slug>.patch. Standard git a/ b/ prefixes.
# A patch whose in-repo path (after a/) starts with `cores/<name>/` is applied
# against vendor/cores/<name>, stripping a/cores/<name>/ (-p3); all others apply
# against vendor/RetroArch, stripping a/ (-p1). Generate core patches with:
#   git -C vendor/cores/<name> diff \
#       --src-prefix=a/cores/<name>/ --dst-prefix=b/cores/<name>/ -- <file>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RA="$ROOT/vendor/RetroArch"
PATCHES="$ROOT/overlay/patches"

[[ -d "$RA/.git" ]] || { echo "FATAL: vendor missing — run scripts/bootstrap.sh" >&2; exit 1; }

shopt -s nullglob
series=("$PATCHES"/[0-9][0-9][0-9][0-9]-*.patch)
if [[ ${#series[@]} -eq 0 ]]; then
    echo "overlay: no patches"
    exit 0
fi

# Decide target tree + strip level by peeking at the first target path in a patch.
target_for() {
    local p="$1" first
    first="$(grep -m1 -E '^\+\+\+ ' "$p" | sed -E 's/^\+\+\+ [ab]\///; s/\t.*//')"
    if [[ "$first" == cores/* ]]; then
        local name; name="$(echo "$first" | cut -d/ -f2)"
        echo "$ROOT/vendor/cores/$name|3"   # strip a/cores/<name>/
    else
        echo "$RA|1"
    fi
}

applied=0 skipped=0
for p in "${series[@]}"; do
    name="$(basename "$p")"
    # Empty/malformed patch guard: an empty patch passes the reverse-dry-run below
    # (nothing to reverse) and is silently counted "already-applied", so its change
    # never reaches a fresh bootstrap. Require at least one real hunk. (A 0-byte
    # 0014 once slipped through exactly this way — the L3+R3 default went missing.)
    grep -q '^@@ ' "$p" || { echo "FATAL: $name has no hunks (empty/malformed patch)" >&2; exit 1; }
    IFS='|' read -r tree strip <<< "$(target_for "$p")"
    [[ -d "$tree/.git" ]] || { echo "FATAL: $name targets $tree which is not vendored" >&2; exit 1; }
    # Reverse-first idempotency: a patch that cleanly REVERSES is already applied
    # (its added lines are present to remove) — the reliable signal. `patch
    # --forward` is unreliable here: it exits 0 when it *skips* an already-applied
    # additive hunk, which would miscount a no-op run as "applied". --force on the
    # probes suppresses patch's interactive direction-guess.
    if patch -p"$strip" -R --force --fuzz=0 --dry-run -d "$tree" < "$p" > /dev/null 2>&1; then
        skipped=$((skipped + 1))
    elif patch -p"$strip" --forward --force --fuzz=0 --dry-run -d "$tree" < "$p" > /dev/null 2>&1; then
        patch -p"$strip" --forward --force --fuzz=0 -d "$tree" < "$p" > /dev/null
        echo "overlay: applied $name -> $(basename "$tree")"
        applied=$((applied + 1))
    else
        echo "FATAL: overlay patch $name neither applied nor appliable (target $tree)" >&2
        exit 1
    fi
done
echo "overlay: $applied applied, $skipped already-applied, $((applied + skipped))/${#series[@]} total"
