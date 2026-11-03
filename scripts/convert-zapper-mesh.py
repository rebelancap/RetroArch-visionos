#!/usr/bin/env python3
"""Convert the NES Zapper OBJ into the compact mesh the visionOS app draws in the hand.

    scripts/convert-zapper-mesh.py <zapper02.obj> <out zapper.mesh> [--tris N]

Input: Max Keeley's "Nintendo Zapper Gun Model" (CC BY 4.0, Blender OBJ + .mtl,
https://sketchfab.com/3d-models/nintendo-zapper-gun-model-dd59e968979b46b3a4f8e151c7de37fe).
Python 3 standard library only.

Steps: parse -> triangulate (quads on the shorter diagonal, n-gons by ear
clipping in their own plane) -> re-base into the gun's MODEL FRAME -> quadric
edge-collapse decimation to <= N triangles (default 6000) -> crease-aware smooth
normals -> bake each vertex's material colour (recoloured to the original grey
Zapper, see COLOURS) -> write the binary below, plus <out dir>/zapper_mesh_stats.txt.

MODEL FRAME (what RAVisionGun.m expects, so no rotation is applied at run time):
metres, +X right, +Y up, +Z back toward the user; the barrel axis is the line
x = y = 0 pointing down -Z; the middle of the handle sits at z = +HAND_Z_M.
Overall length (muzzle to rear) is scaled to LENGTH_M.

FILE FORMAT (little-endian):
  header   char magic[4] = "RAZM"; uint32 version = 1; uint32 vertex_count;
           uint32 index_count
  vertex   float32 position[3]; float32 normal[3]; uint8 rgba[4] (sRGB)   28 bytes
  index    uint32, triangle list, counter-clockwise seen from outside
"""
import heapq
import math
import os
import struct
import sys

# ---------------------------------------------------------------- knobs
LENGTH_M = 0.26        # muzzle to rear cap: a real Zapper is about 26 cm
HAND_Z_M = 0.046       # model z of the handle's middle (RAVisionGun.m RA_GM_HAND_Z_CM)
TARGET_TRIS = 6000
CREASE_DEG = 40.0      # faces meeting at more than this keep a hard edge

# The original grey Zapper: a light grey body with a dark grey grip and barrel
# (the orange one came later).  sRGB 0..1.  The source's `white` material is
# the body and `orange` the grip + barrel; `black` (trigger), `metal` (screws)
# and `red` (the logo) keep their own colours (converted from the .mtl's
# linear Kd to sRGB; black lifted a touch so it still reads as a shape).
GREY_BODY = (0.74, 0.74, 0.73)     # ~ #BDBDBA
GREY_DARK = (0.27, 0.27, 0.28)     # ~ #454547
COLOURS_OVERRIDE = {
    "white":  GREY_BODY,
    "orange": GREY_DARK,
    "black":  (0.08, 0.08, 0.08),
}
# Material importance for decimation (quadric weight): the logo is small and
# thin, so weight it up to keep it legible.
WEIGHT = {"red": 6.0, "metal": 2.0}


def lin_to_srgb(c):
    c = max(0.0, min(1.0, c))
    return c * 12.92 if c <= 0.0031308 else 1.055 * c ** (1 / 2.4) - 0.055


# ---------------------------------------------------------------- vector helpers
def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def mul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def length(a): return math.sqrt(dot(a, a))
def norm(a):
    l = length(a)
    return (a[0] / l, a[1] / l, a[2] / l) if l > 1e-30 else (0.0, 0.0, 0.0)


# ---------------------------------------------------------------- parsing
def parse_mtl(path):
    kd, cur = {}, None
    if not os.path.exists(path):
        return kd
    for line in open(path, encoding="utf-8", errors="replace"):
        p = line.split()
        if not p:
            continue
        if p[0] == "newmtl":
            cur = p[1]
        elif p[0] == "Kd" and cur:
            kd[cur] = tuple(float(x) for x in p[1:4])
    return kd


def parse_obj(path):
    V, polys, mtllib, mat = [], [], None, None
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("v "):
            p = line.split()
            V.append((float(p[1]), float(p[2]), float(p[3])))
        elif line.startswith("f "):
            idx = []
            for t in line.split()[1:]:
                i = int(t.split("/")[0])
                idx.append(i - 1 if i > 0 else len(V) + i)
            polys.append((mat, idx))
        elif line.startswith("usemtl"):
            mat = line.split()[1]
        elif line.startswith("mtllib"):
            mtllib = line.split(None, 1)[1].strip()
    return V, polys, mtllib


# ---------------------------------------------------------------- triangulation
def newell(P):
    n = [0.0, 0.0, 0.0]
    for i in range(len(P)):
        a, b = P[i], P[(i + 1) % len(P)]
        n[0] += (a[1] - b[1]) * (a[2] + b[2])
        n[1] += (a[2] - b[2]) * (a[0] + b[0])
        n[2] += (a[0] - b[0]) * (a[1] + b[1])
    return tuple(n)


def ear_clip(V, idx):
    """Triangulate a simple polygon (any winding kept) in its own plane."""
    P = [V[i] for i in idx]
    n = newell(P)
    ax = max(range(3), key=lambda k: abs(n[k]))
    u, v = [(1, 2), (2, 0), (0, 1)][ax]
    sgn = 1.0 if n[ax] > 0 else -1.0
    pts = [(p[u], p[v]) for p in P]
    rem = list(range(len(idx)))
    tris = []

    def area2(a, b, c):
        return ((pts[b][0] - pts[a][0]) * (pts[c][1] - pts[a][1]) -
                (pts[c][0] - pts[a][0]) * (pts[b][1] - pts[a][1])) * sgn

    def inside(p, a, b, c):
        return (area2(a, b, p) >= 0 and area2(b, c, p) >= 0 and area2(c, a, p) >= 0)

    guard = 0
    while len(rem) > 3 and guard < 10 * len(idx) * len(idx):
        guard += 1
        m = len(rem)
        found = False
        for k in range(m):
            a, b, c = rem[(k - 1) % m], rem[k], rem[(k + 1) % m]
            if area2(a, b, c) <= 0:
                continue
            if any(inside(r, a, b, c) for r in rem if r not in (a, b, c)
                   and pts[r] not in (pts[a], pts[b], pts[c])):
                continue
            tris.append((idx[a], idx[b], idx[c]))
            del rem[k]
            found = True
            break
        if not found:   # degenerate / self-touching: fall back to a fan for the rest
            break
    for k in range(1, len(rem) - 1):
        tris.append((idx[rem[0]], idx[rem[k]], idx[rem[k + 1]]))
    return tris


def triangulate(V, polys):
    out = []
    for mat, idx in polys:
        if len(idx) < 3:
            continue
        if len(idx) == 3:
            out.append((mat, tuple(idx)))
        elif len(idx) == 4:
            a, b, c, d = idx
            if length(sub(V[a], V[c])) <= length(sub(V[b], V[d])):
                out += [(mat, (a, b, c)), (mat, (a, c, d))]
            else:
                out += [(mat, (a, b, d)), (mat, (b, c, d))]
        else:
            out += [(mat, t) for t in ear_clip(V, idx)]
    return out


# ---------------------------------------------------------------- re-basing
def model_frame(V, tris):
    """Barrel forward along source +Z (verified from the part bounds: the barrel
    cylinder runs to max z, the handle hangs below the rear), Y up. Rotate 180
    degrees about Y (x -> -x, z -> -z) so the barrel points down -Z, centre the
    barrel axis on x = y = 0, scale the length to LENGTH_M, slide the handle
    middle to z = HAND_Z_M."""
    used = sorted({i for _, t in tris for i in t})
    zs = [V[i][2] for i in used]
    zmin, zmax = min(zs), max(zs)
    ys = [V[i][1] for i in used]
    ymin, ymax = min(ys), max(ys)
    s = LENGTH_M / (zmax - zmin)

    # barrel: grip/barrel-material vertices in the front 15% of the length
    front = zmax - 0.15 * (zmax - zmin)
    bv = {i for m, t in tris if m == "orange" for i in t if V[i][2] >= front}
    if not bv:
        raise SystemExit("FATAL: no barrel vertices found (material 'orange', front 15%)")
    bx = (min(V[i][0] for i in bv) + max(V[i][0] for i in bv)) / 2
    by = (min(V[i][1] for i in bv) + max(V[i][1] for i in bv)) / 2

    # handle: grip-material vertices well below the barrel; its middle is the
    # mean z of the band halfway down it
    hv = [i for m, t in tris if m == "orange" for i in t if V[i][1] < by - 0.3 * (by - ymin)]
    if not hv:
        raise SystemExit("FATAL: no handle vertices found")
    hy = (min(V[i][1] for i in hv) + max(V[i][1] for i in hv)) / 2
    band = [V[i][2] for i in hv if abs(V[i][1] - hy) < 0.1 * (by - ymin)]
    hz = sum(band) / len(band)

    # source -> model: x' = -(x - bx) s, y' = (y - by) s, z' = -(z - hz) s + HAND_Z_M
    W = [(-(p[0] - bx) * s, (p[1] - by) * s, -(p[2] - hz) * s + HAND_Z_M) for p in V]
    info = dict(scale=s, barrel_axis_src=(bx, by), handle_z_src=hz,
                src_bounds=((min(V[i][0] for i in used), max(V[i][0] for i in used)),
                            (ymin, ymax), (zmin, zmax)))
    return W, info


# ---------------------------------------------------------------- welding
def weld(W, tris):
    """Per material: identical positions become one vertex (materials stay
    separate meshes so colour boundaries never move)."""
    key2i, P, M, F = {}, [], [], []
    for mat, t in tris:
        f = []
        for i in t:
            p = W[i]
            k = (mat, round(p[0], 7), round(p[1], 7), round(p[2], 7))
            j = key2i.get(k)
            if j is None:
                j = key2i[k] = len(P)
                P.append(p)
                M.append(mat)
            f.append(j)
        if f[0] != f[1] and f[1] != f[2] and f[0] != f[2]:
            F.append([f[0], f[1], f[2], mat])
    return P, M, F


# ---------------------------------------------------------------- QEM decimation
def plane_q(n, p, w):
    a, b, c = n
    d = -dot(n, p)
    return [w * x for x in (a * a, a * b, a * c, a * d, b * b, b * c, b * d, c * c, c * d, d * d)]


def q_add(q, r):
    for k in range(10):
        q[k] += r[k]


def q_err(q, p):
    x, y, z = p
    return (q[0] * x * x + 2 * q[1] * x * y + 2 * q[2] * x * z + 2 * q[3] * x +
            q[4] * y * y + 2 * q[5] * y * z + 2 * q[6] * y +
            q[7] * z * z + 2 * q[8] * z + q[9])


def q_opt(q):
    a, b, c, d, e, f, g, h, i, _ = q
    # [a b c; b e f; c f h] x = -[d g i]
    det = a * (e * h - f * f) - b * (b * h - f * c) + c * (b * f - e * c)
    if abs(det) < 1e-18:
        return None
    rx, ry, rz = -d, -g, -i
    x = (rx * (e * h - f * f) - b * (ry * h - f * rz) + c * (ry * f - e * rz)) / det
    y = (a * (ry * h - f * rz) - rx * (b * h - f * c) + c * (b * rz - ry * c)) / det
    z = (a * (e * rz - ry * f) - b * (b * rz - ry * c) + rx * (b * f - e * c)) / det
    return (x, y, z)


def decimate(P, M, F, target):
    P = list(P)
    nV = len(P)
    Q = [[0.0] * 10 for _ in range(nV)]
    vf = [set() for _ in range(nV)]
    for fi, (a, b, c, mat) in enumerate(F):
        n = cross(sub(P[b], P[a]), sub(P[c], P[a]))
        ar = length(n)
        if ar <= 0:
            continue
        n = mul(n, 1 / ar)
        w = WEIGHT.get(mat, 1.0)
        q = plane_q(n, P[a], w)
        for v in (a, b, c):
            q_add(Q[v], q)
            vf[v].add(fi)
    # open-boundary edges: a stiff plane through the edge, perpendicular to its face
    edges = {}
    for fi, (a, b, c, _) in enumerate(F):
        for u, v in ((a, b), (b, c), (c, a)):
            edges.setdefault((min(u, v), max(u, v)), []).append(fi)
    nb = 0
    for (u, v), fs in edges.items():
        if len(fs) != 1:
            continue
        nb += 1
        a, b, c, mat = F[fs[0]]
        fn = norm(cross(sub(P[b], P[a]), sub(P[c], P[a])))
        en = norm(cross(sub(P[v], P[u]), fn))
        q = plane_q(en, P[u], 50.0 * WEIGHT.get(mat, 1.0))
        q_add(Q[u], q)
        q_add(Q[v], q)

    alive_f = [True] * len(F)
    alive_v = [True] * nV
    ver = [0] * nV
    heap = []

    def best(u, v):
        q = [Q[u][k] + Q[v][k] for k in range(10)]
        cands = [P[u], P[v], mul(add(P[u], P[v]), 0.5)]
        o = q_opt(q)
        if o is not None and length(sub(o, cands[2])) < 2.0 * length(sub(P[u], P[v])) + 1e-6:
            cands.append(o)
        bp, be = None, None
        for p in cands:
            e = q_err(q, p)
            if be is None or e < be:
                bp, be = p, e
        return max(be, 0.0), bp

    def push(u, v):
        if u > v:
            u, v = v, u
        e, p = best(u, v)
        heapq.heappush(heap, (e, u, v, ver[u], ver[v], p))

    def nbrs(u):
        s = set()
        for fi in vf[u]:
            s.update(F[fi][:3])
        s.discard(u)
        return s

    for (u, v) in edges:
        push(u, v)

    nf = sum(alive_f)
    while nf > target and heap:
        e, u, v, vu, vv, p = heapq.heappop(heap)
        if not (alive_v[u] and alive_v[v]) or ver[u] != vu or ver[v] != vv:
            continue
        shared = vf[u] & vf[v]
        if not shared:
            continue
        # link condition: the only common neighbours are the shared faces' apexes
        apex = set()
        for fi in shared:
            apex.update(F[fi][:3])
        apex -= {u, v}
        if (nbrs(u) & nbrs(v)) - apex:
            continue
        # no face may flip or collapse to a sliver
        ok = True
        for w in (u, v):
            for fi in vf[w]:
                if fi in shared:
                    continue
                a, b, c, _ = F[fi]
                old = [P[a], P[b], P[c]]
                new = [p if x in (u, v) else P[x] for x in (a, b, c)]
                n0 = cross(sub(old[1], old[0]), sub(old[2], old[0]))
                n1 = cross(sub(new[1], new[0]), sub(new[2], new[0]))
                l0, l1 = length(n0), length(n1)
                if l1 < 1e-14 or (l0 > 0 and dot(n0, n1) < 0.3 * l0 * l1):
                    ok = False
                    break
            if not ok:
                break
        if not ok:
            continue
        # collapse v into u at p
        for fi in shared:
            alive_f[fi] = False
            nf -= 1
            for x in F[fi][:3]:
                vf[x].discard(fi)
        for fi in list(vf[v]):
            f = F[fi]
            for k in range(3):
                if f[k] == v:
                    f[k] = u
            vf[u].add(fi)
        vf[v].clear()
        alive_v[v] = False
        P[u] = p
        q_add(Q[u], Q[v])
        ver[u] += 1
        for w in nbrs(u):
            push(u, w)

    out = [F[i] for i in range(len(F)) if alive_f[i]]
    return P, out, nb


# ---------------------------------------------------------------- normals + output
def build_vertices(P, M, F, colours):
    fn = []
    for a, b, c, _ in F:
        fn.append(cross(sub(P[b], P[a]), sub(P[c], P[a])))   # area-weighted
    vf = {}
    for fi, f in enumerate(F):
        for v in f[:3]:
            vf.setdefault(v, []).append(fi)
    cosc = math.cos(math.radians(CREASE_DEG))
    verts, vkey, idx = [], {}, []
    for fi, f in enumerate(F):
        nf = norm(fn[fi])
        for v in f[:3]:
            s = (0.0, 0.0, 0.0)
            for g in vf[v]:
                if dot(norm(fn[g]), nf) >= cosc:
                    s = add(s, fn[g])
            n = norm(s) if length(s) > 0 else nf
            col = colours[f[3]]
            k = (v, round(n[0], 3), round(n[1], 3), round(n[2], 3))
            j = vkey.get(k)
            if j is None:
                j = vkey[k] = len(verts)
                verts.append((P[v], n, col))
            idx.append(j)
    return verts, idx


def main():
    args = sys.argv[1:]
    target = TARGET_TRIS
    if "--tris" in args:
        k = args.index("--tris")
        target = int(args[k + 1])
        del args[k:k + 2]
    if len(args) != 2:
        print(__doc__.split("\n\n")[1])
        sys.exit(2)
    src, dst = args
    V, polys, mtllib = parse_obj(src)
    kd = parse_mtl(os.path.join(os.path.dirname(src), mtllib or ""))
    mats = sorted({m for m, _ in polys})
    colours = {}
    for m in mats:
        if m in COLOURS_OVERRIDE:
            c = COLOURS_OVERRIDE[m]
        else:
            c = tuple(lin_to_srgb(x) for x in kd.get(m, (0.5, 0.5, 0.5)))
        colours[m] = tuple(int(round(max(0, min(1, x)) * 255)) for x in c) + (255,)

    tris = triangulate(V, polys)
    W, info = model_frame(V, tris)
    P, M, F = weld(W, tris)
    before = len(F)
    before_by = {}
    for f in F:
        before_by[f[3]] = before_by.get(f[3], 0) + 1
    P, F, nboundary = decimate(P, M, F, target)
    after_by = {}
    for f in F:
        after_by[f[3]] = after_by.get(f[3], 0) + 1
    verts, idx = build_vertices(P, M, F, colours)

    with open(dst, "wb") as fo:
        fo.write(struct.pack("<4sIII", b"RAZM", 1, len(verts), len(idx)))
        for p, n, c in verts:
            fo.write(struct.pack("<6f4B", *p, *n, *c))
        fo.write(struct.pack("<%dI" % len(idx), *idx))

    xs = [v[0][0] for v in verts]
    ys = [v[0][1] for v in verts]
    zs = [v[0][2] for v in verts]
    lines = [
        "zapper.mesh — generated by scripts/convert-zapper-mesh.py (do not edit)",
        "source: %s (%d positions, %d polygons, %d materials)" % (os.path.basename(src), len(V), len(polys), len(mats)),
        "triangulated + welded: %d triangles" % before,
        "decimated (quadric edge collapse, target %d): %d triangles, %d open-boundary edges pinned" % (target, len(F), nboundary),
        "output: %d vertices, %d indices, %d bytes" % (len(verts), len(idx), os.path.getsize(dst)),
        "model frame bounds (m): x %.4f..%.4f  y %.4f..%.4f  z %.4f..%.4f" % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)),
        "scale %.6f m per source unit; barrel axis (source x, y) = (%.4f, %.4f); handle middle source z = %.4f -> model z %.3f m"
        % (info["scale"], info["barrel_axis_src"][0], info["barrel_axis_src"][1], info["handle_z_src"], HAND_Z_M),
        "per material (triangles before -> after, sRGB colour):",
    ]
    for m in mats:
        c = colours[m]
        lines.append("  %-7s %6d -> %5d  #%02X%02X%02X" % (m, before_by.get(m, 0), after_by.get(m, 0), c[0], c[1], c[2]))
    stats = "\n".join(lines) + "\n"
    with open(os.path.join(os.path.dirname(os.path.abspath(dst)), "zapper_mesh_stats.txt"), "w") as fo:
        fo.write(stats)
    sys.stdout.write(stats)


if __name__ == "__main__":
    main()
