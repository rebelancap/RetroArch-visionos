#!/usr/bin/env python3
"""Generate overlay/patches/0064-visionos-cocoa-input-spatial-gun.patch.

The frontend half of the NES Zapper aimed with a PSVR2 Sense controller
(the frontend side).

WHY HERE AND NOWHERE ELSE.  The aim never becomes a UIKit touch or pointer
event, so `apple->touches[]` and `window_pos_x/_y` stay at zero for ever; and
`cocoa_input_poll()`'s own translation runs through the *window's* viewport,
which on visionOS is the flat control-surface window and not the world-locked
panel the user is pointing at.  The shell owns the panel geometry, the core
cannot see it, so the shell must write the pointer.  Doing it at the END of
`cocoa_input_poll()` (after upstream's touch loop) puts the coordinates in
place before RetroArch's `input_state` reads them and therefore before
`retro_run` — which matters, because Mesen's Zapper light sensor is evaluated
MID-FRAME against the PPU's current raster position, not at frame end.

WHAT MESEN CONSUMES (vendor/cores/mesen/Libretro/LibretroKeyManager.h:68-95):
port 0's `RETRO_DEVICE_POINTER` X/Y and `RETRO_DEVICE_MOUSE` LEFT/RIGHT —
regardless of which port carries the Zapper device (262, a POINTER subclass,
normally port 2).  Right mouse button is Mesen's own "point off screen" idiom
(Core/Zapper.h:28-32), which is exactly what an aim ray that misses the panel
means.  `cocoa_input.m`'s `RETRO_DEVICE_POINTER` handler takes the `idx == 0`
branch regardless of `touch_count`, so writing `touches[0]` is enough.

`window_pos_x/_y` are written too: they feed `cocoa_lightgun_aiming_state()`,
which gives `RETRO_DEVICE_LIGHTGUN` cores (mame2003-plus light-gun sets) an
approximate aim for three extra lines.  That path still goes through the
window viewport, so it is a bonus, not the Mesen path.

Everything is inside `#if defined(RA_VISION_3D)` — the iOS slice never sees a
byte of it — and inside `ra_vision_gun_active()`, which is false unless a
spatial controller is actually tracked (or the mock pose source is on).  With
no Sense present the function is byte-identical to upstream.

`cocoa_input.m` is touched by NO other overlay patch; keep it that way.

REVISED: the same hook now also feeds the 3dSen scene camera.
`cocoa_input_poll()` is the one place per frame on the EMULATOR thread where the
frontend has already polled the joypad drivers, so the camera can read the pad
through `mfi_joypad`'s own state rather than opening a second GameController
poll that would disagree with RetroArch's.  Reading it through the driver is
also what makes the PSVR2 Sense pair (overlay 0068, which writes `mfi_axes[0]` /
`mfi_buttons[0]`) drive the camera for free.

The tap could not be a NEW patch on `mfi_joypad.m`: 0068's hunk already spans
the whole of `apple_gamecontroller_joypad_poll()`, and overlay patches must not
edit inside each other's hunks.  Revising 0064 — one file, one owner — is the
cheaper of the two, and this is the file the frame's input already lands in.

`ra_vision_camera_input()` is inert unless the immersive loop is running AND the
render thread's gate says a four-plane NES set is on screen (`camera_input = 2`
in 3dsen.cfg overrides).  That gate is the whole conflict story: the right stick
and L2/R2 are dead inputs on an NES pad but are C-buttons and Z on an N64 one.

REVISED after a device session with
a Sense pair on plain-pad NES games.  The first cut wrote the aim whenever an
accessory was tracked, which made a Sense a PERMANENTLY PRESSED TOUCH:
  * in the menu, menu_input_get_touchscreen_hw_state() marks a pressed (or
    moving) pointer ACTIVE every frame, menu_event() then sets
    input_driver_flushing_input = 1 every frame and returns NOOP — every pad
    action, and the L3+R3 toggle (cleared by runloop while flushing), is eaten;
    the only live input is the touch itself, i.e. drag-scroll;
  * when the gun went idle (3D exited, hand lost) touch_count stayed 1 for
    ever, so the menu stayed dead even in 2D.
Now the pointer is written only while it is WANTED — content running, menu not
up, and some port's device is a light-gun/pointer class (Mesen Zapper = 262) —
and the touch/mouse state is RELEASED once when that stops.  The decision is
published to RAVisionGun.m (ra_vision_gun_set_wanted) so the reticle uses the
same gate.  Also added: a beacon of the frontend's input/audio state on every
menu open/close and 1 s / 5 s after a close, so a post-menu wedge is
readable from launch-beacon.log instead of guessed at.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "input/drivers/cocoa_input.m"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0064-visionos-cocoa-input-spatial-gun.patch"

# ---------------------------------------------------------------- include
INC_ANCHOR = """#include "../drivers_keyboard/keyboard_event_apple.h"
#include "../../ui/drivers/cocoa/cocoa_common.h"
#include "../../ui/ui_companion_driver.h"
"""

INC_REPL = INC_ANCHOR + """
#if defined(RA_VISION_3D)
/* app/visionos is on HEADER_SEARCH_PATHS (BaseConfig.xcconfig:212), the same
 * way overlays 0010/0011 reach it. */
#include "RAVision.h"
#include "../../runloop.h"
#include "../../audio/audio_driver.h"
#ifdef HAVE_MENU
#include "../../menu/menu_driver.h"
#endif
/* The Apple joypad driver's own per-frame state, for the scene camera below
 * Declared, not included: mfi_joypad.m has no header. */
extern input_device_driver_t mfi_joypad;

/* one line of frontend input/audio state, for the menu transitions. */
static void ra_vision_input_beacon(const char *what, cocoa_input_data_t *apple)
{
   char                  msg[400];
   runloop_state_t      *rs   = runloop_state_get_ptr();
   input_driver_state_t *is   = input_state_get_ptr();
   audio_driver_state_t *as   = audio_state_get_ptr();
   int                   fl   = -1, alive = -1;
   unsigned              pad  = 0, i;
#ifdef HAVE_MENU
   struct menu_state    *ms   = menu_state_get_ptr();
   if (ms)
      fl = (int)ms->input_driver_flushing_input;
#endif
   if (as && as->current_audio && as->current_audio->alive && as->context_audio_data)
      alive = as->current_audio->alive(as->context_audio_data) ? 1 : 0;
   for (i = 0; i < 16; i++)
      if (mfi_joypad.button(0, (uint16_t)i))
         pad |= 1u << i;
   snprintf(msg, sizeof(msg),
         "input: %s — flushing=%d wait_release=%d block_libretro=%d "
         "core_running=%d paused=%d | audio active=%d alive=%d muted=%d suspended=%d "
         "| dev p1=%u p2=%u | gun active=%d wanted=%d touch_count=%u mouse=%u | pad1=0x%04x",
         what, fl,
         is ? !!(is->flags & INP_FLAG_WAIT_INPUT_RELEASE) : -1,
         is ? !!(is->flags & INP_FLAG_BLOCK_LIBRETRO_INPUT) : -1,
         rs ? !!(rs->flags & RUNLOOP_FLAG_CORE_RUNNING) : -1,
         rs ? !!(rs->flags & RUNLOOP_FLAG_PAUSED) : -1,
         as ? !!(as->flags & AUDIO_FLAG_ACTIVE) : -1, alive,
         as ? !!(as->flags & AUDIO_FLAG_MUTED) : -1,
         as ? !!(as->flags & AUDIO_FLAG_SUSPENDED) : -1,
         input_config_get_device(0), input_config_get_device(1),
         ra_vision_gun_active() ? 1 : 0, ra_vision_gun_wanted() ? 1 : 0,
         (unsigned)apple->touch_count, (unsigned)apple->mouse_buttons, pad);
   RARCH_LOG("[visionOS] %s\\n", msg);
   RA_BeaconMark(msg);
}
#endif
"""

# ------------------------------------------------------------------ hook
POLL_ANCHOR = """      video_driver_translate_coord_viewport_wrap(
            &vp,
            apple->touches[i].screen_x * backing_scale_factor,
            apple->touches[i].screen_y * backing_scale_factor,
            &apple->touches[i].fixed_x,
            &apple->touches[i].fixed_y,
            &apple->touches[i].full_x,
            &apple->touches[i].full_y);
   }
}
"""

POLL_REPL = r'''      video_driver_translate_coord_viewport_wrap(
            &vp,
            apple->touches[i].screen_x * backing_scale_factor,
            apple->touches[i].screen_y * backing_scale_factor,
            &apple->touches[i].fixed_x,
            &apple->touches[i].fixed_y,
            &apple->touches[i].full_x,
            &apple->touches[i].full_y);
   }

#if defined(RA_VISION_3D)
   /* 0064: the visionOS spatial light gun.
    * RAVisionGun.m intersects a tracked PSVR2 Sense controller's aim ray with
    * the world-locked panel and publishes (u, v) over the VISIBLE picture;
    * write it here as port 0's pointer, which is what Mesen's Zapper reads
    * (POINTER X/Y + MOUSE_LEFT, always from port 0, whatever port carries
    * device 262).  Mouse button 2 is Mesen's own "point off screen".
    *
    * ONLY while wanted: content running, menu NOT up, and some port's device
    * is a light-gun or pointer class.  Otherwise a tracked Sense is a touch
    * that never lifts — the menu then flushes every pad action every frame
    * (menu_event -> input_driver_flushing_input = 1) and drag-scrolls with the
    * hand.  When feeding stops, the touch and mouse state are released
    * ONCE, so nothing stays pressed after 3D exits or the hand is lost. */
   {
      static bool s_gun_fed = false;
      bool        want      = false;

      if (ra_vision_gun_active())
      {
         runloop_state_t *rs  = runloop_state_get_ptr();
         settings_t      *set = config_get_ptr();
         bool             run = rs && (rs->flags & RUNLOOP_FLAG_CORE_RUNNING);
#ifdef HAVE_MENU
         struct menu_state *ms = menu_state_get_ptr();
         if (ms && (ms->flags & MENU_ST_FLAG_ALIVE))
            run = false;
#endif
         if (run && set)
         {
            unsigned p, n = set->uints.input_max_users;
            for (p = 0; p < n && p < MAX_USERS; p++)
            {
               unsigned base = input_config_get_device(p) & RETRO_DEVICE_MASK;
               if (base == RETRO_DEVICE_LIGHTGUN || base == RETRO_DEVICE_POINTER)
               {
                  want = true;
                  break;
               }
            }
         }
      }
      ra_vision_gun_set_wanted(want);

      if (want)
      {
         ra_vision_gun_t g;
         if (ra_vision_gun_fetch(&g) && g.valid)
         {
            float u = g.u < 0.0f ? 0.5f : g.u;
            float v = g.v < 0.0f ? 0.5f : g.v;
            int32_t px = (int32_t)lrintf(u * 65535.0f) - 32768;
            int32_t py = (int32_t)lrintf(v * 65535.0f) - 32768;
            if (px >  32767) px =  32767;
            if (px < -32768) px = -32768;
            if (py >  32767) py =  32767;
            if (py < -32768) py = -32768;
            apple->touches[0].confined_x = (int16_t)px;
            apple->touches[0].full_x     = (int16_t)px;
            apple->touches[0].fixed_x    = (int16_t)px;
            apple->touches[0].confined_y = (int16_t)py;
            apple->touches[0].full_y     = (int16_t)py;
            apple->touches[0].fixed_y    = (int16_t)py;
            apple->touch_count           = 1;
            /* Bonus breadth for RETRO_DEVICE_LIGHTGUN cores; still translated
             * through the window viewport, so approximate on visionOS. */
            apple->window_pos_x          = (int16_t)px;
            apple->window_pos_y          = (int16_t)py;
            apple->mouse_buttons         = (g.trigger   ? 1u : 0u)
                                         | (g.offscreen ? 2u : 0u);
            s_gun_fed                    = true;
         }
      }
      else if (s_gun_fed)
      {
         /* Lift the synthetic touch and buttons exactly once. */
         apple->touch_count   = 0;
         apple->mouse_buttons = 0;
         s_gun_fed            = false;
      }
   }

   /* frontend input/audio state on every menu open/close, and again
    * 1 s and 5 s after a close — the post-menu "no input, no audio" wedge is
    * then a log line, not a guess. */
   {
      static int s_menu_prev = -1;
      static int s_post      = 0;
      int        menu_now    = 0;
#ifdef HAVE_MENU
      struct menu_state *ms = menu_state_get_ptr();
      menu_now = (ms && (ms->flags & MENU_ST_FLAG_ALIVE)) ? 1 : 0;
#endif
      if (menu_now != s_menu_prev)
      {
         if (s_menu_prev >= 0)
            ra_vision_input_beacon(menu_now ? "menu OPEN" : "menu CLOSED", apple);
         s_post      = (!menu_now && s_menu_prev == 1) ? 1 : 0;
         s_menu_prev = menu_now;
      }
      else if (s_post)
      {
         s_post++;
         if (s_post == 61)
            ra_vision_input_beacon("+1s after menu close", apple);
         else if (s_post == 301)
         {
            ra_vision_input_beacon("+5s after menu close", apple);
            s_post = 0;
         }
      }
   }

   /* 0064b: the 3dSen scene camera.  The mfi driver has already been
    * polled for this frame, so its port-1 state is exactly what the core is
    * about to be handed — read it here and there is no second, disagreeing
    * poll anywhere in the app.  Axis 2/3 are the right stick (raw, +Y up),
    * 4/5 the analog triggers; the driver returns only the matching half of a
    * signed axis, so both halves are summed.  Everything downstream is inert
    * until the immersive loop is up and its gate says NES. */
   {
      int16_t rx = mfi_joypad.axis(0, AXIS_POS(2)) + mfi_joypad.axis(0, AXIS_NEG(2));
      int16_t ry = mfi_joypad.axis(0, AXIS_POS(3)) + mfi_joypad.axis(0, AXIS_NEG(3));
      int16_t l2 = mfi_joypad.axis(0, AXIS_POS(4));
      int16_t r2 = mfi_joypad.axis(0, AXIS_POS(5));
      bool    l3 = mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_L3) != 0;
      bool    r3 = mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_R3) != 0;

      /* A pad without analog triggers still reports L2/R2 as buttons. */
      if (!l2 && mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_L2)) l2 = 32767;
      if (!r2 && mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_R2)) r2 = 32767;

      ra_vision_camera_input(rx / 32767.0f, ry / 32767.0f,
                             l2 / 32767.0f, r2 / 32767.0f, l3, r3);
   }
#endif
}
'''

text = SRC.read_text()
if "ra_vision_gun_active" in text:
    sys.exit("0064 already applied to vendor — reverse it out before regenerating")

for name, anchor in (("include", INC_ANCHOR), ("poll", POLL_ANCHOR)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")

LEAD = TRAIL = 3
hunks = []
for anchor, repl in ((INC_ANCHOR, INC_REPL), (POLL_ANCHOR, POLL_REPL)):
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    old_lines = anchor.rstrip("\n").split("\n")
    new_lines = repl.rstrip("\n").split("\n")
    lead = text[:start].split("\n")[:-1][-LEAD:]
    rest = text[start + len(anchor):].split("\n")[:TRAIL]
    while rest and rest[-1] == "":
        rest.pop()
    body = [" " + l if l else " " for l in lead]
    body += ["-" + l if l else "-" for l in old_lines]
    body += ["+" + l if l else "+" for l in new_lines]
    body += [" " + l if l else " " for l in rest]
    hunks.append((line_no - len(lead),
                  len(lead) + len(old_lines) + len(rest),
                  len(lead) + len(new_lines) + len(rest),
                  body))

offset = 0
out = [f"diff --git a/{REL} b/{REL}", f"--- a/{REL}", f"+++ b/{REL}"]
for start, oldc, newc, body in hunks:
    out.append(f"@@ -{start},{oldc} +{start + offset},{newc} @@")
    out.extend(body)
    offset += newc - oldc

OUT.write_text("\n".join(out) + "\n")
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
