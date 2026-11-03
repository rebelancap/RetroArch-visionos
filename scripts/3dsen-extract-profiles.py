#!/usr/bin/env python3
r"""3dsen-extract-profiles.py: copy the profiles out of YOUR 3dSen install.

If you own 3dSenVR or 3dSen PC, the game's official per-game 3D profiles
(`.3dn` files) ship inside its install as a Unity asset bundle named
`defaultprofiles_*.bundle` somewhere under its `StreamingAssets` folder
(Windows: `3dSenVR_Data/StreamingAssets/aa/StandaloneWindows64/`; a macOS
`.app`: `Contents/Resources/Data/StreamingAssets/...`). This script reads that
bundle and writes each profile out as a plain `.3dn` file, which RetroArch's
3D mode reads from `RetroArch/system/3dsen/`. Works on Windows, macOS and
Linux; it needs only Python 3 and UnityPy.

    macOS/Linux:  python3 scripts/3dsen-extract-profiles.py <where> <out dir>
    Windows:      py scripts\3dsen-extract-profiles.py <where> <out dir>

  <where>    the game's install folder, its .app, its StreamingAssets folder
             (all searched recursively for defaultprofiles_*.bundle), or the
             path of the bundle itself.
  <out dir>  where the .3dn files go (created if missing).

Requires UnityPy (https://github.com/K0lb3/UnityPy):

    python3 -m pip install UnityPy        (Windows: py -m pip install UnityPy)

The profiles are Geod's work. Use this only on a copy of 3dSen you own, keep the
results for your own use, and do not redistribute them.
"""
import os
import sys

USAGE = ("usage: 3dsen-extract-profiles.py <install folder | .app | "
         "StreamingAssets folder | .bundle> <out folder>")


def clean_arg(a):
    # Windows: "C:\Games\3dSenVR\" reaches us as C:\Games\3dSenVR" (the
    # trailing backslash escapes the closing quote), so drop stray quotes.
    a = a.strip().strip('"').strip("'")
    return os.path.expanduser(a)


def find_bundles(path):
    if os.path.isfile(path):
        return [path]
    hits = []
    # followlinks: a Steam library on another drive is often a symlink on macOS
    for root, _dirs, files in os.walk(path, followlinks=True):
        for f in files:
            if f.startswith("defaultprofiles_") and f.endswith(".bundle"):
                hits.append(os.path.join(root, f))
    return sorted(hits)


def main():
    if len(sys.argv) != 3:
        sys.exit(USAGE)
    src, out = clean_arg(sys.argv[1]), clean_arg(sys.argv[2])
    if not os.path.exists(src):
        sys.exit("not found: %s" % src)
    try:
        import UnityPy
    except ImportError:
        sys.exit("needs UnityPy:  python3 -m pip install UnityPy   "
                 "(Windows: py -m pip install UnityPy)")

    print("searching %s ..." % src)
    bundles = find_bundles(src)
    if not bundles:
        sys.exit("no defaultprofiles_*.bundle found under %s\n"
                 "point this at the folder 3dSen is installed in "
                 "(the one holding its StreamingAssets folder)." % src)
    for b in bundles:
        print("found %s" % b)

    os.makedirs(out, exist_ok=True)
    n = 0
    for b in bundles:
        k = 0
        env = UnityPy.load(b)
        for obj in env.objects:
            if obj.type.name != "TextAsset":
                continue
            data = obj.read()
            raw = data.m_Script
            # UnityPy returns a binary TextAsset as str with surrogate escapes;
            # round-trip it back to the original bytes rather than re-encoding.
            if isinstance(raw, str):
                raw = raw.encode("utf-8", "surrogateescape")
            else:
                raw = bytes(raw)
            name = data.m_Name.replace("/", "_").replace("\\", "_")
            with open(os.path.join(out, name + ".3dn"), "wb") as f:
                f.write(raw)
            k += 1
        n += k
        print("%s: %d profiles" % (os.path.basename(b), k))
    if not n:
        sys.exit("the bundle held no profiles; is this a 3dSen install?")
    print("wrote %d profiles (.3dn) -> %s" % (n, os.path.abspath(out)))
    print("copy them to RetroArch/system/3dsen/ on the headset (Files app).")


if __name__ == "__main__":
    main()
