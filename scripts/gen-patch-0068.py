#!/usr/bin/env python3
"""Generate overlay/patches/0068-visionos-mfi-psvr2-sense-pad.patch.

The tester's .31 device log:

    mfi connect: name='PlayStation VR2 Sense Controller (L)' cat='Spatial Controller'
        extended=0 micro=0 haptics=1 battery=1 motion=1 light=0 elements=13
    mfi exclude: 'PlayStation VR2 Sense Controller (L)' has no extendedGamepad
        profile, not given a port

so the only controllers the tester owns for the headset cannot open a game, and the
whole Zapper track is untestable.  0054's exclude rule is right about what it
was written for — a ghost with no usable profile must not eat a core-visible
port — but a Sense PAIR is not a ghost.  visionOS 26 vends them through
`physicalInputProfile` under the UNSIDED element names added in that release
(GCInputThumbstick / GCInputThumbstickButton / GCInputTrigger /
GCInputGripButton; see XROS26.5.sdk/.../GCInputNames.h) plus the ordinary face
and menu names.  There is simply no `extendedGamepad`, which is all 0054 tested.

THE PATCH: synthesise ONE libretro pad on PORT 1 from the pair.

  * ONE hunk, on the UPSTREAM body of apple_gamecontroller_joypad_poll().  It
    deliberately does NOT hook 0054's connect/disconnect handlers — overlay
    patches must not edit inside each other's hunks (the first cut of this patch
    did, and `apply-overlay.sh` refused to run twice).  The pair is discovered by
    scanning [GCController controllers] in the poll itself.
  * The pair NEVER enters mfi_controllers[], so slot policy is untouched
    and a Backbone Pro always takes the lowest free slot.  mfi_spatial_poll()
    stands down the moment slot 0 holds a real gamepad.
  * Both halves are read with both the unsided and the sided aliases and OR'd,
    because which half carries which alias is undocumented and there is no
    spatial controller in the simulator.  Every element name each device vends is
    beaconed once, so a wrong guess is a one-line correction from the log.
  * The LEFT stick also drives the d-pad (0.5 deflection): a Sense has none and
    both the menu and every NES game need one.
  * The menu toggle needs nothing new — overlay 0014 already binds L3+R3 on
    visionOS and both clicks are mapped.

  Map: left stick -> d-pad + analog 0/1 | right stick -> analog 2/3 |
  triggers -> L2/R2 (+ analog 4/5) | grips -> L/R | cross/A -> B | circle/B -> A |
  square/X -> Y | triangle/Y -> X | Menu -> START | Options -> SELECT |
  L3+R3 -> RetroArch menu.

The Zapper (app/visionos/RAVisionGun.m) reads the same trigger and grip off the
same profile on the immersive render thread.  Both readers are read-only against
GameController state, so they coexist.

Gun mode: while a light gun is in play (ra_vision_gun_wanted(), the
 gate) the triggers belong to the gun alone, so they set neither L2/R2 nor
analog 4/5 on the pad (the camera zoom moves to the grips, RAVisionGun.m).  The
gate is one poll behind (overlay 0064 sets it at the end of cocoa_input_poll),
which is invisible at 60 Hz.

visionOS only.  The iOS/tvOS builds compile exactly upstream's code.
0054 is the only other patch on this file and its hunks are at 491/531/568;
this one is at 215.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "input/drivers_joypad/mfi_joypad.m"
SRC = ROOT / "vendor/RetroArch" / REL
OUT = ROOT / "overlay/patches/0068-visionos-mfi-psvr2-sense-pad.patch"

A1 = '''static void apple_gamecontroller_joypad_poll(void)
{
    if (!apple_gamecontroller_available())
        return;

    for (GCController *controller in [GCController controllers])
    {
       /* If we have not assigned a slot to this controller yet, ignore it. */
       if (      controller
             && (controller.playerIndex >= 0)
             && (controller.playerIndex < MAX_USERS)
             && !mfi_controller_is_siri_remote(controller))
          apple_gamecontroller_joypad_poll_internal(controller,
                (uint32_t)controller.playerIndex);
    }
}
'''

R1 = '''#if TARGET_OS_VISION
/* --- 0068 /: a PSVR2 Sense PAIR as one libretro pad on port 1 ---------
 *
 * 0054 refuses a port to anything without an `extendedGamepad` profile, which
 * is right for a ghost device but wrong for a spatial controller: visionOS 26
 * vends a Sense through `physicalInputProfile` under the UNSIDED element names
 * added in that release (GCInputThumbstick / ThumbstickButton / Trigger /
 * GripButton) plus the ordinary face and menu names.  Without this the only
 * controllers the tester owns for the headset cannot even open a game.
 *
 * Deliberately SELF-CONTAINED and anchored on upstream text only: it discovers
 * the pair by scanning [GCController controllers] here rather than hooking
 * 0054's connect/disconnect handlers, because overlay patches must not edit
 * inside each other's hunks.  Nothing here touches mfi_controllers[], so
 * slot policy is untouched and a real gamepad always wins port 1.
 *
 * The map is Which half vends which
 * alias is undocumented and there is no spatial controller in the simulator, so
 * both halves are read with both the unsided and the sided names and OR'd, and
 * every element name each device actually vends is beaconed once — that line in
 * launch-beacon.log is what makes a wrong guess a one-line correction. */

extern void RA_BeaconMark(const char *stage);
extern input_device_driver_t mfi_joypad;
static void mfi_joypad_autodetect_add(unsigned autoconf_pad, const char *display_name);
#if defined(RA_VISION_3D)
/* RAVisionGun.m: a light gun is in play (content running, no menu, a
 * light-gun/pointer port).  The triggers then only fire the gun. */
extern bool ra_vision_gun_wanted(void);
#endif

static __weak GCController *mfi_spatial_seen[2];   /* beaconed already */
static bool                 mfi_spatial_named;

static void mfi_spatial_beacon(const char *fmt, ...)
{
   char    msg[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(msg, sizeof(msg), fmt, ap);
   va_end(ap);
   RARCH_LOG("[MFI] %s\\n", msg);
   RA_BeaconMark(msg);
}

static bool mfi_is_spatial(GCController *c)
{
   if (!c)
      return false;
   if (@available(visionOS 26.0, *))
      return [c.productCategory isEqualToString:GCProductCategorySpatialController];
   return false;
}

/* "(L)"/"left" in the vendor name, else "(R)"/"right", else unknown (-1). */
static int mfi_spatial_hand(GCController *c)
{
   NSString *n = c.vendorName ?: @"";
   if ([n containsString:@"(L)"] || [n localizedCaseInsensitiveContainsString:@"left"])
      return 0;
   if ([n containsString:@"(R)"] || [n localizedCaseInsensitiveContainsString:@"right"])
      return 1;
   return -1;
}

static void mfi_spatial_beacon_elements(GCController *c)
{
   char buf[400];
   int  off = 0;
   buf[0] = '\\0';
   if (@available(visionOS 26.0, *))
   {
      for (NSString *k in c.physicalInputProfile.elements.allKeys)
      {
         const char *s = [k UTF8String];
         int n;
         if (!s)
            continue;
         n = snprintf(buf + off, sizeof(buf) - (size_t)off, "%s'%s'", off ? " " : "", s);
         if (n < 0 || off + n >= (int)sizeof(buf))
            break;
         off += n;
      }
   }
   mfi_spatial_beacon("mfi spatial elements: '%s' -> %s",
                      c.vendorName ? [c.vendorName UTF8String] : "(unnamed)",
                      off ? buf : "(none)");
}

static bool mfi_spatial_btn(GCPhysicalInputProfile *in, NSString *a, NSString *b)
{
   GCControllerButtonInput *e;
   if (!in)
      return false;
   if (a && (e = in.buttons[a]) && e.isPressed)
      return true;
   if (b && (e = in.buttons[b]) && e.isPressed)
      return true;
   return false;
}

static float mfi_spatial_val(GCPhysicalInputProfile *in, NSString *a, NSString *b)
{
   GCControllerButtonInput *e;
   if (!in)
      return 0.0f;
   if (a && (e = in.buttons[a]))
      return e.value;
   if (b && (e = in.buttons[b]))
      return e.value;
   return 0.0f;
}

static GCControllerDirectionPad *mfi_spatial_stick(GCPhysicalInputProfile *in,
                                                   NSString *a, NSString *b)
{
   GCControllerDirectionPad *d;
   if (!in)
      return nil;
   if (a && (d = in.dpads[a]))
      return d;
   if (b && (d = in.dpads[b]))
      return d;
   return nil;
}

static void mfi_spatial_poll(void)
{
   GCController *half[2] = { nil, nil };
   uint32_t      buttons = 0;
   int16_t       axes[MAX_MFI_AXES];
   int           hand, i;

   if (!(@available(visionOS 26.0, *)))
      return;

   for (GCController *c in [GCController controllers])
   {
      int h;
      if (!mfi_is_spatial(c))
         continue;
      h = mfi_spatial_hand(c);
      if (h < 0)
         h = half[0] ? 1 : 0;
      if (half[h])
         h = h ? 0 : 1;
      if (half[h])
         continue;                     /* more than two: ignore the rest */
      half[h] = c;
      if (mfi_spatial_seen[h] != c)
      {
         mfi_spatial_seen[h] = c;
         mfi_spatial_beacon_elements(c);
         mfi_spatial_beacon("mfi spatial: '%s' -> %s half of the synthetic "
                            "port-1 pad",
                            c.vendorName ? [c.vendorName UTF8String] : "(unnamed)",
                            h ? "right" : "left");
      }
   }

   if (!half[0] && !half[1])
   {
      mfi_spatial_seen[0] = mfi_spatial_seen[1] = nil;
      if (mfi_spatial_named)
      {
         mfi_spatial_named = false;
         mfi_buttons[0]    = 0;
         memset(mfi_axes[0], 0, sizeof(mfi_axes[0]));
         if (!mfi_controllers[0])
            input_autoconfigure_disconnect(0, mfi_joypad.ident);
         mfi_spatial_beacon("mfi spatial: pair gone, port 1 released");
      }
      return;
   }

   /* A real gamepad owns port 1 whenever one is connected. */
   if (mfi_controllers[0])
   {
      if (mfi_spatial_named)
      {
         mfi_spatial_named = false;
         mfi_spatial_beacon("mfi spatial: standing down, a gamepad holds port 1");
      }
      return;
   }
   if (!mfi_spatial_named)
   {
      mfi_spatial_named = true;
      mfi_joypad_autodetect_add(0, "PSVR2 Sense (pair)");
      mfi_spatial_beacon("mfi spatial: pair drives port 1");
   }

   memset(axes, 0, sizeof(axes));
   for (hand = 0; hand < 2; hand++)
   {
      GCController             *c = half[hand];
      GCPhysicalInputProfile   *in;
      GCControllerDirectionPad *stick;
      float                     trig;
      if (!c)
         continue;
      in = c.physicalInputProfile;

      /* RetroPad swaps A/B and X/Y against GameController's names, exactly as
       * apple_gamecontroller_joypad_poll_internal() does it. */
      if (mfi_spatial_btn(in, GCInputButtonA, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_B);
      if (mfi_spatial_btn(in, GCInputButtonB, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_A);
      if (mfi_spatial_btn(in, GCInputButtonX, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_Y);
      if (mfi_spatial_btn(in, GCInputButtonY, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_X);
      if (mfi_spatial_btn(in, GCInputButtonMenu, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_START);
      if (mfi_spatial_btn(in, GCInputButtonOptions, nil))
         buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_SELECT);

      if (mfi_spatial_btn(in, GCInputGripButton,
                          hand ? GCInputRightShoulder : GCInputLeftShoulder))
         buttons |= (1 << (hand ? RETRO_DEVICE_ID_JOYPAD_R
                                : RETRO_DEVICE_ID_JOYPAD_L));

      trig = mfi_spatial_val(in, GCInputTrigger,
                             hand ? GCInputRightTrigger : GCInputLeftTrigger);
#if defined(RA_VISION_3D)
      /* Gun mode: the triggers fire the gun and nothing else. */
      if (ra_vision_gun_wanted())
         trig = 0.0f;
#endif
      if (trig > 0.5f)
         buttons |= (1 << (hand ? RETRO_DEVICE_ID_JOYPAD_R2
                                : RETRO_DEVICE_ID_JOYPAD_L2));
      axes[hand ? 5 : 4] = (int16_t)(trig * 32767.0f);

      if (mfi_spatial_btn(in, GCInputThumbstickButton,
                          hand ? GCInputRightThumbstickButton
                               : GCInputLeftThumbstickButton))
         buttons |= (1 << (hand ? RETRO_DEVICE_ID_JOYPAD_R3
                                : RETRO_DEVICE_ID_JOYPAD_L3));

      stick = mfi_spatial_stick(in, GCInputThumbstick,
                                hand ? GCInputRightThumbstick
                                     : GCInputLeftThumbstick);
      if (stick)
      {
         float x = stick.xAxis.value, y = stick.yAxis.value;
         axes[hand ? 2 : 0] = (int16_t)(x * 32767.0f);
         axes[hand ? 3 : 1] = (int16_t)(y * 32767.0f);
         /* The LEFT stick is also the D-PAD: a Sense has none, and both the
          * RetroArch menu and every NES game need one. */
         if (!hand)
         {
            if (x < -0.5f) buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_LEFT);
            if (x >  0.5f) buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_RIGHT);
            if (y >  0.5f) buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_UP);
            if (y < -0.5f) buttons |= (1 << RETRO_DEVICE_ID_JOYPAD_DOWN);
         }
      }
   }

   mfi_buttons[0] = buttons;
   for (i = 0; i < MAX_MFI_AXES; i++)
      mfi_axes[0][i] = axes[i];
}
#endif /* TARGET_OS_VISION */

static void apple_gamecontroller_joypad_poll(void)
{
    if (!apple_gamecontroller_available())
        return;

    for (GCController *controller in [GCController controllers])
    {
       /* If we have not assigned a slot to this controller yet, ignore it. */
       if (      controller
             && (controller.playerIndex >= 0)
             && (controller.playerIndex < MAX_USERS)
             && !mfi_controller_is_siri_remote(controller))
          apple_gamecontroller_joypad_poll_internal(controller,
                (uint32_t)controller.playerIndex);
    }

#if TARGET_OS_VISION
    /* 0068: a PSVR2 Sense pair drives port 1 when no real gamepad does. */
    mfi_spatial_poll();
#endif
}
'''

text = SRC.read_text()
if "mfi_spatial_poll" in text:
    sys.exit("0068 already applied to vendor - reverse it out before regenerating")

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
