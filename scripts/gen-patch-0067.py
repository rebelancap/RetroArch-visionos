#!/usr/bin/env python3
"""Generate overlay/patches/0067-visionos-cocoa-input-null-data-guard.patch.

THE CRASH IN THE TESTER'S .31 DEVICE RUN ("app hangs loading a second game").

Reproduced in the Apple Vision Pro simulator. Sequence: load SMB,
enter 3D, exit 3D, close content, load Ice Hockey.  `Documents/crash.txt` and
`RetroArch-2026-09-07-163431.ips` agree:

    EXC_BAD_ACCESS (SIGSEGV) KERN_INVALID_ADDRESS at 0x0000000000000010
    main thread:  cocoa_input_state + 1400
               <- menu_input_get_touchscreen_hw_state + 88
               <- menu_event + 892
               <- runloop_check_state + 18204
               <- runloop_iterate + 1192
               <- ra_pace_iterate + 32
               <- -[CocoaView step:] + 488

`cocoa_input_state()` casts its `data` argument to `cocoa_input_data_t *` and
dereferences it with no NULL check.  `data` is `input_st->current_data`, which
is NULL for the whole window in which the input driver is down: between
`driver_uninit()` and `drivers_init()` on a content swap, and permanently after
a content load ABORTS partway (which is what "already linked" failure
did).

Upstream never sees it because on every other platform one loop owns both
iteration and content load/unload.  On visionOS a CADisplayLink drives the run
loop (overlay 0033) and keeps firing while the main thread is inside a load, so
`step:` re-enters `runloop_iterate()` mid-swap — the identical mechanism that
made overlay 0066 necessary for `core_run()`.  This is 0066 for the input side.

THE PATCH: three lines at the top of `cocoa_input_state()`.  A NULL `data` is a
crash by definition, so returning 0 ("nothing pressed, pointer nowhere") cannot
regress anything.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "input/drivers/cocoa_input.m"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0067-visionos-cocoa-input-null-data-guard.patch"

A1 = """   cocoa_input_data_t *apple = (cocoa_input_data_t*)data;

   switch (device)
"""
R1 = """   cocoa_input_data_t *apple = (cocoa_input_data_t*)data;

   /* 0067: the input driver is DOWN (input_st->current_data == NULL) for the
    * whole window of a content swap, and stays down if a content load aborts.
    * visionOS drives the run loop from a CADisplayLink (overlay 0033), so
    * runloop_check_state() -> menu_event() -> this function keeps being called
    * inside that window and dereferences NULL.  Same fault class as 0066's
    * core_run() guard; "nothing pressed" is the right answer for "no input
    * driver right now". */
   if (!apple)
      return 0;

   switch (device)
"""

text = SRC.read_text()
if "0067" in text:
    sys.exit("0067 already applied to vendor - reverse it out before regenerating")

n = text.count(A1)
if n != 1:
    sys.exit(f"anchor matched {n} times (want 1)")
start = text.index(A1)
line_no = text[:start].count("\n") + 1
old_lines = A1.rstrip("\n").split("\n")
new_lines = R1.rstrip("\n").split("\n")
LEAD = TRAIL = 3
lead = text[:start].split("\n")[:-1][-LEAD:] if start else []
rest = text[start + len(A1):].split("\n")[:TRAIL]
while rest and rest[-1] == "":
    rest.pop()

body = [" " + l if l else " " for l in lead]
body += ["-" + l if l else "-" for l in old_lines]
body += ["+" + l if l else "+" for l in new_lines]
body += [" " + l if l else " " for l in rest]
old_count = len(lead) + len(old_lines) + len(rest)
new_count = len(lead) + len(new_lines) + len(rest)
hunk_start = line_no - len(lead)

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n--- a/{REL}\n+++ b/{REL}\n"
    f"@@ -{hunk_start},{old_count} +{hunk_start},{new_count} @@\n"
    + "\n".join(body) + "\n"
)
print(f"wrote {OUT}")
subprocess.run(["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"),
                "-i", str(OUT)], check=True)
print("dry-run OK")
