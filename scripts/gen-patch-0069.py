#!/usr/bin/env python3
"""Generate overlay/patches/0069-cores-pcsx-rearmed-no-ptrace-traceme.patch.

PCSX-ReARMed's retro_init() does, on every Mach target except tvOS,

    // magic sauce to make the dynarec work on iOS
    syscall(SYS_ptrace, 0 /*PTRACE_TRACEME*/, 0, 0, 0);

That is the old "ptrace yourself so the kernel lets you mmap PROT_EXEC" JIT
trick. Our xros/xrsimulator slice is built DYNAREC=0, so the makefile passes
-DDRC_DISABLE and there is no dynarec to feed: the call buys nothing.

What it costs (measured in the lane-1 sim): PT_TRACE_ME is
process-wide and cannot be undone, so the moment a PS1 game is loaded the
WHOLE RetroArch app becomes a traced process with no tracer for the rest of
the session — `ps` shows `SXs` instead of `Ss`. A traced process does not
die on a signal; it stops. SIGTERM (`simctl terminate`, and what the system
sends on an app update/reinstall) left the app in state `TXs` forever; even
SIGKILL did not reap it until the simulator was shut down. RetroArch's own
JITSupport.m warns about exactly this ("ptracing ourselves confuses the
kernel and will cause bad things ... (hangs...) if an exception or signal
occurs"). It would also turn any later crash in any core into a silent hang
instead of a crash report. snes9x in the same app/session: `Ss`, SIGTERM exits.

THE PATCH: skip the call when DRC_DISABLE is defined (the interpreter-only
build). Builds with the dynarec keep upstream behaviour byte for byte.

Run from the repo root, against a PRISTINE vendor/cores/pcsx-rearmed.
"""
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = "pcsx-rearmed"
REL = "frontend/libretro.c"
SRC = ROOT / "vendor/cores" / CORE / REL
OUT = ROOT / "overlay/patches/0069-cores-pcsx-rearmed-no-ptrace-traceme.patch"

A1 = """#if defined(__MACH__) && !defined(TVOS)
   // magic sauce to make the dynarec work on iOS
   syscall(SYS_ptrace, 0 /*PTRACE_TRACEME*/, 0, 0, 0);
#endif
"""
R1 = """#if defined(__MACH__) && !defined(TVOS) && !defined(DRC_DISABLE)
   // magic sauce to make the dynarec work on iOS
   // (0069: skipped in interpreter-only builds - PT_TRACE_ME there buys no JIT
   // and leaves the whole host app self-traced, so signals stop it, not end it)
   syscall(SYS_ptrace, 0 /*PTRACE_TRACEME*/, 0, 0, 0);
#endif
"""

text = SRC.read_text()
if "0069:" in text:
    sys.exit("0069 already applied to vendor - reverse it out before regenerating")
n = text.count(A1)
if n != 1:
    sys.exit(f"anchor matched {n} times (want 1)")
new = text.replace(A1, R1)

diff = difflib.unified_diff(
    text.splitlines(keepends=True), new.splitlines(keepends=True),
    fromfile=f"a/cores/{CORE}/{REL}", tofile=f"b/cores/{CORE}/{REL}", n=3)
body = "".join(diff)
if not body:
    sys.exit("empty diff")
OUT.write_text(f"diff --git a/cores/{CORE}/{REL} b/cores/{CORE}/{REL}\n" + body)
print(f"wrote {OUT}")
subprocess.run(["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores" / CORE),
                "-i", str(OUT)], check=True)
print("dry-run OK")
