#!/usr/bin/env python3
"""Generate overlay/patches/0066-visionos-core-run-null-guard.patch.

THE CRASH IN THE TESTER'S .28 DEVICE RUN.

Both `.ips` reports from 2026-09-07 (00:51:53 and 00:55:20) are the same fault:

    EXC_BAD_ACCESS (KERN_PROTECTION_FAILURE) at 0x0, CODESIGNING "Invalid Page"
    main thread:  ?+0
               <- core_run + 224
               <- runloop_iterate + 4140
               <- ra_pace_iterate + 32
               <- -[CocoaView step:] + 488

`?+0` at address zero under `core_run` is a call through a NULL function
pointer: `core_run()` ends with an unguarded

    current_core->retro_run();

and `retro_run` is NULL for the window in which no core is loaded — between
`core_unload()` NULLing the symbol table and the frontend settling on the dummy
core, and again while `retro_load_game` is in flight. Upstream never sees it
because on every other platform the runloop is driven by ONE loop that also owns
content load/unload, so nothing else can call `runloop_iterate()` mid-swap.

On visionOS it is driven by a **CADisplayLink** (`-[CocoaView step:]`, overlay
0033). The display link keeps firing while the main thread is inside a content
load/unload — RetroArch's task queue and the menu both pump the run loop — so
`step:` re-enters `runloop_iterate()` in exactly that window. `runloop_check_state()`
still answers RUNLOOP_STATE_ITERATE (the menu is not up; the 3D ornament is not
the RetroArch menu), so `core_run()` runs and dereferences NULL.

The tester hit it twice: entering 3D and then loading content, and closing content
while 3D was up.

THE PATCH: two lines at the top of `core_run()`. A NULL `retro_run` is a crash
by definition, so returning early cannot regress anything; the frame is simply
skipped, which is what the platform means by "no core is loaded right now". One
RARCH_ERR the first time it fires, so a build that starts skipping frames for a
different reason says so instead of looking like a stall.

Line 8462 in runloop.c; the only other overlay that touches this file is 0040,
whose hunks are at 1288 / 1449 / 2949.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "runloop.c"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0066-visionos-core-run-null-guard.patch"

A1 = """void core_run(void)
{
   runloop_state_t *runloop_st = &runloop_state;
   struct retro_core_t *
      current_core             = &runloop_st->current_core;
"""
R1 = """void core_run(void)
{
   runloop_state_t *runloop_st = &runloop_state;
   struct retro_core_t *
      current_core             = &runloop_st->current_core;

   /* 0066: no core loaded -> retro_run is NULL, and calling it is a jump to
    * address 0.  Cannot happen where one loop owns both iteration and content
    * load/unload; on visionOS a CADisplayLink drives the run loop (overlay
    * 0033) and keeps firing while the main thread is inside a load or an
    * unload, so it re-enters here mid-swap.  Skipping the frame is exactly
    * what "no core right now" should do. */
   if (!current_core->retro_run)
   {
      static bool ra_warned_null_retro_run = false;
      if (!ra_warned_null_retro_run)
      {
         ra_warned_null_retro_run = true;
         RARCH_ERR("[Core]: core_run() with no retro_run - frame skipped.\\n");
      }
      return;
   }
"""

text = SRC.read_text()
if "0066" in text or "ra_warned_null_retro_run" in text:
    sys.exit("0066 already applied to vendor - reverse it out before regenerating")

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
