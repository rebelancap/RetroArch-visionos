#!/usr/bin/env python3
"""Generate overlay/patches/0054-visionos-mfi-deterministic-slot-policy.patch.

THE BUG (the tester, on device): "RetroArch keeps making my Backbone Pro
controller port 2, so I can't control Mario in SM64. Force-quit doesn't help. No
other devices connected."

WHAT THE DRIVER DOES TODAY (`input/drivers_joypad/mfi_joypad.m`, upstream):

    apple_gamecontroller_joypad_connect(GCController *controller)
    {
        signed desired_index = (int32_t)controller.playerIndex;
        if (!(desired_index >= 0 && desired_index < MAX_MFI_CONTROLLERS))
           desired_index     = 0;
        ...
        if (!mfi_controllers[desired_index])  /* take the desired slot */
        else                                  /* else lowest free slot */
    }

RetroArch maps joypad slot N to user/port N+1, so slot 1 IS "port 2". There are
exactly two ways to land in slot 1 with a single controller connected:

  (a) `controller.playerIndex` already reads 1 when the connect notification
      fires, and the driver honours it verbatim. GameController hands back a
      *persisted* player index for a controller that has been assigned one
      before (it is the player-LED identity, owned by the system and the
      controller, not by the app) — which is exactly why **force-quitting
      RetroArch does not help**: the state does not live in our process.
  (b) Something else enumerated through `[GCController controllers]` first and
      took slot 0. On visionOS that could be a keyboard/HID device coalesced
      into a controller, a microGamepad-profile device, a system/spatial input
      device, or the Backbone Pro's own second HID profile.

We cannot tell (a) from (b) from here — there is no Vision Pro on this machine
and the simulator does not reproduce visionOS's own input enumeration. So this
patch does BOTH: it names the culprit in the tester's next log, and it makes either
cause harmless.

THE BEACON (`mfi connect:` / `mfi exclude:` / `mfi evict:` / `mfi slot:` /
`mfi roster:` / `mfi disconnect:`
in Documents/launch-beacon.log, visionOS only). Every connect logs vendorName,
productCategory, which profiles the device presents (extended / micro /
keyboard), whether it has haptics/battery/motion/light, its physical input
element count, the **incoming playerIndex**, and the slot the policy then gave
it; plus the full four-slot roster after every connect and disconnect. If (a) is
the cause the log reads `incoming playerIndex=1`; if (b) is, the ghost appears as
its own `mfi connect:` line with its name and category. Either way the next log
settles it. Uses RA_BeaconMark directly (ui_cocoatouch.m, same binary — the
dlsym dance of 0042/0049 is only needed from a core dylib).

THE POLICY (visionOS only; `#if TARGET_OS_VISION`, so the iOS/tvOS targets are
byte-for-byte upstream). The first cut of this patch merely *relegated* ghosts to
higher slots. The tester's follow-up on .23 shows that is not enough: with the pad
forced onto port 1 by a Device Index override, SNES Super Mario Kart then refused
to start a **1-player** game and offered only 2P — i.e. the ghost was still a
live, core-visible controller on port 2, and the game counted it as a second
player. A device that cannot play must not occupy a port at all. So:

  1. A controller that presents an **extendedGamepad** profile (and is not a
     Siri-remote-style micro device) is a *gamepad*. It ignores whatever
     playerIndex the system persisted for it and claims the **lowest free
     slot** — so a physical pad always lands on port 1 when nothing else real
     is connected.
  2. Anything else is **EXCLUDED**: it is named in the beacon, its playerIndex
     is cleared, and the connect returns without registering it, exactly the way
     upstream already refuses the Siri remote. It never gets a slot, never gets
     `input_autoconfigure_connect`, and therefore never appears to a core as a
     connected player.
  3. A ghost that somehow already holds a slot when a gamepad connects (a device
     that gained an extendedGamepad profile after connecting, or state from an
     earlier policy) is **evicted** — released on the driver's own
     `apple_gamecontroller_joypad_disconnect()` path so its haptics engine is
     torn down properly — and the gamepad takes its slot.
  4. If every slot is genuinely held by real gamepads, the connect is refused
     loudly instead of silently overwriting slot 0.

Not touched, deliberately: **the user's Device Index override**. Slot != port.
RetroArch maps user N to joypad `input_playerN_joypad_index` (settings, saved in
retroarch.cfg); this patch only decides which *slot* a device occupies, so an
explicit Device Index in Settings -> Input -> Port N still wins on top of it,
exactly as before. The tester can therefore leave his workaround in place or clear
it; either way the pad ends up on port 1 and nothing else holds a port.

Run from the repo root, against a vendor tree with 0054 not yet applied.
"""
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "input/drivers_joypad/mfi_joypad.m"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0054-visionos-mfi-deterministic-slot-policy.patch"

# ---------------------------------------------------------------- helpers ----
HELPERS_ANCHOR = """static void apple_gamecontroller_joypad_connect(GCController *controller)
{
"""

HELPERS = """#if TARGET_OS_VISION
/* --- 0054: deterministic controller slot policy + enumeration beacon --------
 * See scripts/gen-patch-0054.py for the whole reasoning. visionOS only; the
 * iOS/tvOS builds compile exactly upstream's code. */
#include <stdarg.h>

extern void RA_BeaconMark(const char *stage);

static void apple_gamecontroller_joypad_disconnect(GCController *controller);

static void mfi_beacon(const char *fmt, ...)
{
   char    msg[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(msg, sizeof(msg), fmt, ap);
   va_end(ap);
   RARCH_LOG("[MFI] %s\\n", msg);
   RA_BeaconMark(msg);
}

static const char *mfi_display_name(GCController *c)
{
   const char *s;
   if (!c)
      return "-";
   if (!c.vendorName)
      return "(unnamed)";
   s = [c.vendorName UTF8String];
   return s ? s : "(unnamed)";
}

/* A device that can actually drive an emulator: an extendedGamepad profile.
 * Everything else that can turn up in [GCController controllers] on visionOS —
 * a Siri-remote-style microGamepad, a keyboard/HID device coalesced into a
 * controller, a system/spatial input device, or a physical pad's own secondary
 * profile — is a ghost as far as port 1 is concerned. */
static bool mfi_controller_is_gamepad(GCController *controller)
{
   if (!controller)
      return false;
   if (mfi_controller_is_siri_remote(controller))
      return false;
   return controller.extendedGamepad != nil;
}

static void mfi_beacon_roster(const char *when)
{
   char roster[400];
   int  off = 0;
   int  i;
   roster[0] = '\\0';
   for (i = 0; i < MAX_MFI_CONTROLLERS; i++)
   {
      GCController *c = mfi_controllers[i];
      int n = snprintf(roster + off, sizeof(roster) - (size_t)off,
                       "%s%d=%s%s", i ? " " : "", i, mfi_display_name(c),
                       (c && !mfi_controller_is_gamepad(c)) ? "[ghost]" : "");
      if (n < 0 || off + n >= (int)sizeof(roster))
         break;
      off += n;
   }
   mfi_beacon("mfi roster (%s): %s", when, roster);
}

/* Pick the slot a GAMEPAD should occupy, evicting a ghost that is squatting
 * below it. Returns -1 when every slot is held by a real gamepad. Ghosts never
 * reach here — they are excluded at the top of the connect handler. */
static int mfi_vision_pick_slot(GCController *controller)
{
   int i;
   int slot = -1;

   /* Lowest free slot, ignoring whatever playerIndex the system persisted for
    * this controller. */
   for (i = 0; i < MAX_MFI_CONTROLLERS; i++)
      if (!mfi_controllers[i])
      {
         slot = i;
         break;
      }

   /* ...and if a ghost is sitting below that, take its slot outright. */
   for (i = 0; i < MAX_MFI_CONTROLLERS; i++)
   {
      GCController *occ = mfi_controllers[i];

      if (!occ)
         continue;                      /* free slot: already considered above */
      if (slot >= 0 && i > slot)
         break;                         /* nothing lower left to reclaim */
      if (mfi_controller_is_gamepad(occ))
         continue;                      /* a real pad keeps its slot */

      /* Release slot i on the driver's own path (haptics teardown + autoconfig
       * disconnect) and DROP the ghost: a device that cannot play must not
       * occupy a core-visible port at all (Super Mario Kart offered only a 2P
       * game while one did). */
      apple_gamecontroller_joypad_disconnect(occ);
      mfi_buttons[i] = 0;
      memset(mfi_axes[i], 0, sizeof(mfi_axes[0]));
      occ.playerIndex = GCControllerPlayerIndexUnset;
      mfi_beacon("mfi evict: '%s' dropped from slot %d, a gamepad takes port %d",
                 mfi_display_name(occ), i, i + 1);

      slot = i;
      break;
   }

   return slot;
}
#endif /* TARGET_OS_VISION */

static void apple_gamecontroller_joypad_connect(GCController *controller)
{
"""

# ---------------------------------------------------- connect-side policy ----
POLICY_ANCHOR = """    if (mfi_controllers[desired_index] != controller)
    {
"""

POLICY = """#if TARGET_OS_VISION
    /* 0054: name the device in the OTA-only log, then place it deterministically. */
    {
        const char *cat  = "(n/a)";
        int         elem = 0;
        int         slot;

        if (@available(visionOS 1.0, *))
        {
            if (controller.productCategory)
                cat = [controller.productCategory UTF8String];
            elem = (int)controller.physicalInputProfile.elements.count;
        }
        mfi_beacon("mfi connect: name='%s' cat='%s' extended=%d micro=%d "
                   "haptics=%d battery=%d motion=%d light=%d elements=%d "
                   "incoming playerIndex=%d",
                   mfi_display_name(controller), cat,
                   controller.extendedGamepad != nil,
                   controller.microGamepad != nil,
                   controller.haptics != nil,
                   controller.battery != nil,
                   controller.motion != nil,
                   controller.light != nil,
                   elem, (int)controller.playerIndex);

        /* A device with no extendedGamepad profile cannot play anything, and a
         * core counts every connected port as a live player — Super Mario Kart
         * offered the tester only a 2P game while one of these held port 2. Refuse
         * it here, exactly as upstream refuses the Siri remote. */
        if (!mfi_controller_is_gamepad(controller))
        {
            mfi_beacon("mfi exclude: '%s' has no extendedGamepad profile, "
                       "not given a port", mfi_display_name(controller));
            controller.playerIndex = GCControllerPlayerIndexUnset;
            mfi_beacon_roster("after exclude");
            return;
        }

        slot = mfi_vision_pick_slot(controller);
        if (slot < 0)
        {
            mfi_beacon("mfi connect: '%s' REFUSED, all %d slots busy",
                       mfi_display_name(controller), MAX_MFI_CONTROLLERS);
            RARCH_ERR("[MFI] Too many connected controllers, ignoring.\\n");
            return;
        }
        mfi_beacon("mfi slot: '%s' -> slot %d (port %d), policy=gamepad:lowest-free",
                   mfi_display_name(controller), slot, slot + 1);
        desired_index = slot;
    }
#endif

    if (mfi_controllers[desired_index] != controller)
    {
"""

# ----------------------------------------------------- roster after connect --
TAIL_ANCHOR = """    mfi_joypad_autodetect_add((unsigned)controller.playerIndex, [controller.vendorName cStringUsingEncoding:NSUTF8StringEncoding]);
}
"""

TAIL = """    mfi_joypad_autodetect_add((unsigned)controller.playerIndex, [controller.vendorName cStringUsingEncoding:NSUTF8StringEncoding]);
#if TARGET_OS_VISION
    mfi_beacon_roster("after connect");
#endif
}
"""

# ---------------------------------------------------- disconnect beacon ------
DISC_ANCHOR = """static void apple_gamecontroller_joypad_disconnect(GCController* controller)
{
    NSInteger pad = controller.playerIndex;

    if (pad < 0 || pad >= MAX_MFI_CONTROLLERS)
        return;
"""

DISC = """static void apple_gamecontroller_joypad_disconnect(GCController* controller)
{
    NSInteger pad = controller.playerIndex;

#if TARGET_OS_VISION
    mfi_beacon("mfi disconnect: name='%s' slot %d", mfi_display_name(controller),
               (int)pad);
#endif

    if (pad < 0 || pad >= MAX_MFI_CONTROLLERS)
        return;
"""

EDITS = [
    ("helpers", HELPERS_ANCHOR, HELPERS),
    ("policy", POLICY_ANCHOR, POLICY),
    ("tail", TAIL_ANCHOR, TAIL),
    ("disconnect", DISC_ANCHOR, DISC),
]

text = SRC.read_text()
if "mfi_vision_pick_slot" in text:
    sys.exit("0054 already applied to vendor — reverse it out before regenerating")

new = text
for name, anchor, repl in EDITS:
    n = new.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")
    new = new.replace(anchor, repl)

if new == text:
    sys.exit("no change produced")

diff = difflib.unified_diff(
    text.splitlines(keepends=True),
    new.splitlines(keepends=True),
    fromfile=f"a/{REL}",
    tofile=f"b/{REL}",
    n=3,
)
OUT.write_text(f"diff --git a/{REL} b/{REL}\n" + "".join(diff))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p1", "--dry-run", "--force", "--fuzz=0",
     "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
