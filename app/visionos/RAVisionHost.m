/* RAVisionHost.m — the UIKit half of the visionOS shell.
 *
 * On visionOS the app entry is SwiftUI (an ImmersiveSpace can only be declared
 * from a SwiftUI App), so RetroArch's own UIKit stack is HOSTED rather than
 * self-launching:
 *
 *   RAVisionApp.swift  WindowGroup -> RAHostView -> RAVisionHostViewController
 *                                                     |
 *                                                     +-- [CocoaView get]  (RetroArch's root VC)
 *                                                     +-- curtain (shown while in 3D)
 *
 * RetroArch's -applicationDidFinishLaunching is deferred (overlay 0010) and run
 * from here instead, once the hosted view is inside a live window.  That
 * ordering is load-bearing: rarch_main brings up the Metal driver, and a driver
 * that comes up against a view with no window has no sensible drawable size and
 * would size its layer from zero bounds.
 *
 * This file also owns the 3D enter/exit sequencing, which the guide is emphatic
 * about and which every sibling port got wrong at least once:
 *   ENTER: engine offscreen FIRST, then park the window, then open the space.
 *   EXIT:  stop the render loop and WAIT for it, then dismiss the space, then
 *          put the engine back on the window.
 */

#import "RAVision.h"

#if defined(RA_VISION_3D)

#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <unistd.h>
#import <stdlib.h>

/* $(SRCBASE) (the RetroArch source root) is on the header search path. */
#import "ui/drivers/cocoa/cocoa_common.h"
#import "ui/drivers/cocoa/apple_platform.h"
#include "command.h"
#include "libretro.h"
/* dev hook (RA3D_KEYS): input/drivers/cocoa_input.m */
extern void apple_direct_input_keyboard_event(bool down, unsigned code,
                                              uint32_t character, uint32_t mod,
                                              unsigned device);

/* Implemented in Swift (@_cdecl).  RA_SetImmersiveMode flips the SwiftUI state
 * that actually opens or dismisses the immersive space; the audio stage lives
 * in Swift because setIntendedSpatialExperience is far pleasanter to spell
 * there than through its ObjC options dictionary. */
extern void RA_SetImmersiveMode(bool on);
extern void RA_SetAudioFrontStage(bool on);
extern void RA_OpenSettingsSheet(void);
extern void RA_SetHandsHidden(bool hidden);   /* `hands` knob */

/* Deferred launch trampoline, defined in ui_cocoatouch.m (overlay 0010). */
extern void ra_vision_launch(void);

static void ra_vision_seed_documents(void);
static void ra_ra_heal_retry(int left);

/* --------------------------------------------------------------- mode state */

static _Atomic bool s_active = false;   /* 3D armed (offscreen redirect live)  */

bool ra_vision_3d_active(void) { return atomic_load_explicit(&s_active, memory_order_relaxed); }

/* ------------------------------------------------------------ host view ctrl */

@interface RAVisionHostViewController : UIViewController
@property (nonatomic, weak)   UIView  *gameView;
@property (nonatomic, strong) UIView  *curtain;
@end

static __weak RAVisionHostViewController *s_host = nil;

@implementation RAVisionHostViewController

- (void)viewDidLoad
{
   [super viewDidLoad];
   RA_BeaconMark("host viewDidLoad");
   {  /* which build variant this is. Only the public build carries
       * RABuildVariant (build-visionos-app.sh RA_PUBLIC=1); its absence means
       * the private sideload build with the bundled 3dSen profiles. */
      NSDictionary *info = NSBundle.mainBundle.infoDictionary;
      NSString *variant  = info[@"RABuildVariant"];
      char m[256];
      snprintf(m, sizeof(m), "build: %s v%s (%s)",
               [variant isEqualToString:@"public"] ? "public" : "private",
               [info[@"CFBundleShortVersionString"] description].UTF8String ?: "?",
               [info[@"CFBundleVersion"] description].UTF8String ?: "?");
      RA_BeaconMark(m);
   }
   self.view.backgroundColor = UIColor.blackColor;
   s_host = self;

   /* Host RetroArch's root view controller as a child.  CocoaView is the same
    * object the frontend uses on iOS; the render view is added to ITS view by
    * -setViewType:, so everything downstream (Metal view, touch, pointer,
    * GCEventInteraction pad claim) is unchanged. */
   UIViewController *cv = (UIViewController *)[CocoaView get];
   [self addChildViewController:cv];
   cv.view.frame = self.view.bounds;
   cv.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
   [self.view addSubview:cv.view];
   [cv didMoveToParentViewController:self];

   self.gameView = cv.view;

   /* Curtain: in 3D the window is only a control surface, and a frozen last
    * frame floating there is confusing.  Covered rather than hidden — the
    * render view has to stay in the hierarchy. */
   UIView *c = [[UIView alloc] initWithFrame:self.view.bounds];
   c.backgroundColor  = UIColor.blackColor;
   c.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
   c.hidden           = YES;

   UILabel *l = [UILabel new];
   l.text          = @"Playing in 3D";
   l.textColor     = [UIColor colorWithWhite:0.75 alpha:1.0];
   l.font          = [UIFont systemFontOfSize:26.0 weight:UIFontWeightSemibold];
   l.textAlignment = NSTextAlignmentCenter;
   l.translatesAutoresizingMaskIntoConstraints = NO;
   [c addSubview:l];
   [[l.centerXAnchor constraintEqualToAnchor:c.centerXAnchor] setActive:YES];
   [[l.centerYAnchor constraintEqualToAnchor:c.centerYAnchor] setActive:YES];

   [self.view addSubview:c];
   self.curtain = c;
}

- (void)viewWillAppear:(BOOL)animated
{
   [super viewWillAppear:animated];
   RA_BeaconMark("host viewWillAppear");
}

- (void)viewDidAppear:(BOOL)animated
{
   [super viewDidAppear:animated];
   RA_BeaconMark("host viewDidAppear");

   /* RetroArch reads [RetroArch_iOS get].window for the scene geometry request.
    * Under the SwiftUI lifecycle the window belongs to the WindowGroup — hand
    * it over, but never set its rootViewController (SwiftUI owns that). */
   RetroArch_iOS *app = [RetroArch_iOS get];
   if (app && self.view.window)
      app.window = self.view.window;

   ra_vision_seed_documents();
   ra_vision_settings_load();
   ra_vision_launch();      /* idempotent; the first live window wins */
   {  /* undo run-ahead settings an interrupted 3D session left */
      static bool healed = false;
      if (!healed)
      {
         healed = true;
         ra_ra_heal_retry(10);
         ra_vision_zapper_auto_start();
      }
   }

   /* The window has just been handed over, so this is the earliest point at
    * which the aspect lock can actually be armed (item 2 /). The Swift
    * onAppear call retries until it gets here anyway; this makes the common
    * case immediate. */
   ra_vision_arm_aspect_lock();

   /* Validation hooks.  simctl cannot tap an ornament, and opening a
    * retroarch:// URL through LaunchServices raises a confirmation sheet that
    * also cannot be tapped — so the harness needs a way in.  All three are
    * environment-gated and therefore inert in every normal launch; what they
    * buy is the ability to exercise the entire 3D path in the simulator rather
    * than only on the headset.
    *
    * RA3D_CONTENT + RA3D_CORE: load content through exactly the code path the
    * retroarch:// topshelf URL uses, just without LaunchServices in the way. */
   {
      const char *content = getenv("RA3D_CONTENT");
      const char *core    = getenv("RA3D_CORE");
      if (content && core)
      {
         NSString *u = [NSString stringWithFormat:@"retroarch://topshelf?path=%@&core_path=%@",
            [@(content) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet],
            [@(core) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet]];
         NSLog(@"[RA3D] RA3D_CONTENT set — loading %s", content);
         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{
            NSLog(@"[RA3D] content load -> %d", (int)RA_HandleOpenURL([NSURL URLWithString:u]));
         });
      }
   }
   /* RA3D_CONTENT2 + RA3D_CONTENT2_AT: reproduce the tester's "close content, load
    * a second game" sequence without a menu to tap. Closes content at
    * RA3D_CONTENT2_AT seconds, loads RA3D_CONTENT2 three seconds later. */
   {
      const char *content2 = getenv("RA3D_CONTENT2");
      const char *content  = getenv("RA3D_CONTENT");
      const char *core     = getenv("RA3D_CORE");
      const char *at       = getenv("RA3D_CONTENT2_AT");
      double when          = at ? atof(at) : 0.0;
      if (content2 && content && core && when > 0.0)
      {
         NSString *u = [NSString stringWithFormat:@"retroarch://topshelf?path=%@&core_path=%@",
            [@(content2) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet],
            [@(core) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet]];
         NSString *u1 = [NSString stringWithFormat:@"retroarch://topshelf?path=%@&core_path=%@",
            [@(content) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet],
            [@(core) stringByAddingPercentEncodingWithAllowedCharacters:
               NSCharacterSet.URLQueryAllowedCharacterSet]];
         const char *cyc = getenv("RA3D_CONTENT2_CYCLES");
         int cycles = cyc ? atoi(cyc) : 1;
         if (cycles < 1) cycles = 1;
         for (int k = 0; k < cycles; k++)
         {
            double t   = when + k * 14.0;
            NSString *target = (k % 2 == 0) ? u : u1;
            int kk = k;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               char m[64]; snprintf(m, sizeof(m), "harness: close content (cycle %d)", kk);
               RA_BeaconMark(m);
               command_event(CMD_EVENT_UNLOAD_CORE, NULL);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((t + 3.0) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               char m[64]; snprintf(m, sizeof(m), "harness: load content (cycle %d)", kk);
               RA_BeaconMark(m);
               NSLog(@"[RA3D] cycle %d load -> %d", kk,
                     (int)RA_HandleOpenURL([NSURL URLWithString:target]));
            });
            /* RA3D_CYCLE_3D: re-enter 3D on every cycle, which is what
               exercises the core-image revalidation after a swap. */
            if (getenv("RA3D_CYCLE_3D"))
            {
               dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((t + 6.0) * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                  RA_BeaconMark("harness: re-enter 3D");
                  ra_vision_enter_3d(true);
               });
               dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((t + 11.0) * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                  RA_BeaconMark("harness: leave 3D");
                  ra_vision_enter_3d(false);
               });
            }
         }
      }
   }
   /* RA3D_3DSEQ="sec:1,sec:0,..." enters (1) / leaves (0) 3D at
    * each time, so the 2D -> 3D -> 2D window round trip can be run twice in
    * one launch. Inert unless set. */
   {
      const char *seq = getenv("RA3D_3DSEQ");
      if (seq && *seq)
      {
         char *dup = strdup(seq), *save = NULL, *tok;
         for (tok = strtok_r(dup, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
         {
            double at = 0.0; int on = 0;
            if (sscanf(tok, "%lf:%d", &at, &on) != 2 || at <= 0.0) continue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               RA_BeaconMark(on ? "harness: 3dseq enter 3D" : "harness: 3dseq leave 3D");
               ra_vision_enter_3d(on != 0);
            });
         }
         free(dup);
      }
   }
   {
      const char *autoEnter = getenv("RA3D_AUTOENTER");
      double delay = autoEnter ? atof(autoEnter) : 0.0;
      if (delay > 0.0)
      {
         NSLog(@"[RA3D] RA3D_AUTOENTER=%.1fs — will enter 3D automatically", delay);
         dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                        dispatch_get_main_queue(), ^{ ra_vision_enter_3d(true); });
         const char *autoSettings = getenv("RA3D_AUTOSETTINGS");
         double sheet = autoSettings ? atof(autoSettings) : 0.0;
         if (sheet > 0.0)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sheet * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ RA_OpenSettingsSheet(); });
         const char *autoExit = getenv("RA3D_AUTOEXIT");
         double leave = autoExit ? atof(autoExit) : 0.0;
         if (leave > delay)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(leave * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ra_vision_enter_3d(false); });
      }
   }
   /* (dev only): RA3D_KEYS="sec:key[:hold],..." presses a keyboard key at
    * <sec> seconds after launch for <hold> seconds (default 0.15) — the sim has
    * no gamepad, and RetroArch's default player-1 keyboard binds (x = A,
    * z = B, enter = Start, rshift = Select, arrows = d-pad) reach the core
    * through apple_direct_input_keyboard_event exactly like a real keyboard. */
   {
      const char *keys = getenv("RA3D_KEYS");
      if (keys && *keys)
      {
         char *dup = strdup(keys), *save = NULL, *tok;
         for (tok = strtok_r(dup, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
         {
            double at = 0.0, hold = 0.15;
            char   name[16] = { 0 };
            unsigned code = 0;
            if (sscanf(tok, "%lf:%15[^:]:%lf", &at, name, &hold) < 2) continue;
            if      (!strcmp(name, "enter"))  code = RETROK_RETURN;
            else if (!strcmp(name, "rshift")) code = RETROK_RSHIFT;
            else if (!strcmp(name, "up"))     code = RETROK_UP;
            else if (!strcmp(name, "down"))   code = RETROK_DOWN;
            else if (!strcmp(name, "left"))   code = RETROK_LEFT;
            else if (!strcmp(name, "right"))  code = RETROK_RIGHT;
            else if (!strcmp(name, "f1"))     code = RETROK_F1;        /* menu toggle */
            else if (!strcmp(name, "bksp"))   code = RETROK_BACKSPACE; /* menu back   */
            else if (strlen(name) == 1 && name[0] >= 'a' && name[0] <= 'z')
               code = RETROK_a + (unsigned)(name[0] - 'a');
            if (!code) continue;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               char m[64]; snprintf(m, sizeof(m), "harness: key %u down", code);
               RA_BeaconMark(m);
               apple_direct_input_keyboard_event(true, code, 0, 0, RETRO_DEVICE_KEYBOARD);
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((at + hold) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
               apple_direct_input_keyboard_event(false, code, 0, 0, RETRO_DEVICE_KEYBOARD);
            });
         }
         free(dup);
         NSLog(@"[RA3D] RA3D_KEYS scheduled: %s", keys);
      }
   }
}

- (void)setCurtainVisible:(BOOL)on
{
   self.curtain.hidden = !on;
   [self.view bringSubviewToFront:self.curtain];
}

@end

/* visionOS and iOS HIDE an app's folder in the Files app while its Documents
 * directory is empty.  RetroArch's whole data story runs through that folder —
 * ROMs and BIOS in, and launch-beacon.log / crash.txt / retroarch.log out — so
 * an empty Documents means the app is invisible in Files and there is no way
 * either to feed it or to diagnose it.  Writing one small file is all it takes
 * to make the folder appear, and it doubles as the instructions.
 *
 * Never overwrites: if anything is already there, this does nothing. */
static void ra_vision_seed_documents(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   if (!docs)
      return;

   NSFileManager *fm = NSFileManager.defaultManager;
   NSString *readme  = [docs stringByAppendingPathComponent:@"READ ME — put ROMs here.txt"];
   if ([fm fileExistsAtPath:readme])
      return;

   NSArray *existing = [fm contentsOfDirectoryAtPath:docs error:NULL];
   NSUInteger visible = 0;
   for (NSString *name in existing)
      if (![name hasPrefix:@"."])
         visible++;

   NSString *text =
      @"RetroArch - Apple Vision Pro\n"
       "============================\n"
       "\n"
       "Put ROMs and BIOS files in THIS folder (or any folder inside it).\n"
       "In RetroArch: Load Content, then browse here.\n"
       "\n"
       "3D mode\n"
       "-------\n"
       "Look at the RetroArch window and you will see a small pill floating\n"
       "just below it with '3D' and a gear. Tap 3D to put the game on a screen\n"
       "in your room; the gear has screen size, distance, Stereo Depth and room\n"
       "dimming. Tap Exit 3D to come back.\n"
       "\n"
       "NES games get real depth: the background and the sprites are placed at\n"
       "different distances, so characters stand off the scenery. Other systems\n"
       "show a flat screen for now.\n"
       "\n"
       "If something goes wrong\n"
       "-----------------------\n"
       "This folder also collects launch-beacon.log, crash.txt and\n"
       "ra-vp3d-report.log. Sending those makes any problem diagnosable without\n"
       "the headset being here.\n";

   NSError *err = nil;
   if (![text writeToFile:readme atomically:YES encoding:NSUTF8StringEncoding error:&err])
      NSLog(@"[RA3D] could not seed Documents: %@", err.localizedDescription);
   else
      NSLog(@"[RA3D] seeded Documents (%lu existing entries) so the folder shows in Files",
            (unsigned long)visible);
}

/* Swift's UIViewControllerRepresentable calls this. */
UIViewController *RA_MakeHostViewController(void)
{
   return [RAVisionHostViewController new];
}

/* URL opens.  Under the SwiftUI/scene lifecycle UIKit delivers URLs to the
 * SCENE, so -application:openURL:options: on the delegate is never called and
 * both the retroarch:// scheme and "Open in RetroArch" from Files would be
 * dead in this build.  RARootView's .onOpenURL forwards here, and here we hand
 * the URL to the delegate method that already knows what to do with it. */
bool RA_HandleOpenURL(NSURL *url)
{
   RetroArch_iOS *app = [RetroArch_iOS get];
   if (!app || !url)
      return false;
   return [app application:[UIApplication sharedApplication] openURL:url options:@{}] ? true : false;
}

/* ----------------------------------------------------------- window parking */

/* visionOS cannot move a window programmatically but it can resize one.  In 3D
 * the window is just the control surface, so shrink it to a card.  The size is
 * captured at the very START of entry and guarded against re-capture: grabbing
 * it after the space opens, or re-grabbing an already-parked size, is exactly
 * how a sibling's window "stayed tiny" forever. */
static CGSize s_savedWindowSize = { 0, 0 };
static BOOL   s_windowParked    = NO;
/* true from 3D exit until the window is back at its pre-3D size
 * and re-locked. While it is set nobody else may "arm the lock at the current
 * size" — the current size is still the parked card. */
static BOOL     s_windowRestoring = NO;
static unsigned s_restoreGen      = 0;

static const char *ra_restr_name(UIWindowSceneResizingRestrictions r)
{
   switch (r)
   {
      case UIWindowSceneResizingRestrictionsNone:     return "none";
      case UIWindowSceneResizingRestrictionsUniform:  return "uniform";
      case UIWindowSceneResizingRestrictionsFreeform: return "freeform";
      default:                                        return "?";
   }
}

/* one second after a request, beacon what the window actually
 * became, so the tester's log shows whether visionOS honoured it. */
static void ra_window_readback(const char *tag)
{
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
      UIWindow *w = [RetroArch_iOS get].window;
      char m[128];
      if (!w) return;
      snprintf(m, sizeof m, "window: now %.0fx%.0f aspect %.3f (1 s after %s)",
               w.bounds.size.width, w.bounds.size.height,
               w.bounds.size.height > 1.0 ? w.bounds.size.width / w.bounds.size.height : 0.0,
               tag);
      RA_BeaconMark(m);
   });
}

static void ra_request_window_size_t(CGSize size,
                                     UIWindowSceneResizingRestrictions restr,
                                     const char *tag)
{
   dispatch_async(dispatch_get_main_queue(), ^{
      UIWindow      *w  = [RetroArch_iOS get].window;
      UIWindowScene *ws = w.windowScene;
      if (!ws || size.width < 1.0 || size.height < 1.0)
         return;
      UIWindowSceneGeometryPreferencesVision *p =
         [[UIWindowSceneGeometryPreferencesVision alloc] initWithSize:size];
      p.minimumSize          = CGSizeMake(320.0, 240.0);
      p.resizingRestrictions = restr;
      {
         char m[192];
         snprintf(m, sizeof m, "window: request size %.0fx%.0f aspect %.3f restrictions %s "
                  "(%s; win %.0fx%.0f)", size.width, size.height, size.width / size.height,
                  ra_restr_name(restr), tag, w.bounds.size.width, w.bounds.size.height);
         RA_BeaconMark(m);
      }
      [ws requestGeometryUpdateWithPreferences:p errorHandler:^(NSError *e) {
         if (e)
         {
            char m[192];
            snprintf(m, sizeof m, "window: request FAILED (%s): %s", tag,
                     e.localizedDescription.UTF8String ? e.localizedDescription.UTF8String : "?");
            RA_BeaconMark(m);
         }
      }];
      ra_window_readback(tag);
   });
}

static void ra_request_window_size_r(CGSize size,
                                     UIWindowSceneResizingRestrictions restr)
{
   ra_request_window_size_t(size, restr, "aspect lock");
}


/* ------------------------------------------------- 2D window aspect lock
 *
 * item 2.  The emulator's window must never letterbox, so the user's
 * corner-drag has to stay ratio-locked to whatever aspect the running core
 * reports.  The per-content SHAPE is already handled in the frontend:
 * video_driver_set_aspect_ratio() -> cocoa_vision_window_match_aspect()
 * (overlay 0015/0018) requests a window at video_st->aspect_ratio with
 * UIWindowSceneResizingRestrictionsUniform, and it is re-fired on every
 * SET_GEOMETRY / SET_SYSTEM_AV_INFO and on every menu open/close.  So the
 * aspect is genuinely driven by the core's reported geometry, not by a
 * hardcoded per-core table — bsnes-hd in widescreen locks to 16:9 for free.
 *
 * Two windows in which the lock is NOT armed, both of them ours to close, and
 * both closed here rather than by editing patch 0015's hunk:
 *
 *   1. match_aspect returns early when the window ALREADY matches the target
 *      within 2 % — a correct optimisation for the size, but it also skips the
 *      restriction, so a launch that happens to start near 16:9 leaves the
 *      window freely resizable until some later aspect change.
 *   2. ra_unpark_window() restores the pre-3D size with Freeform, so exiting
 *      the 3D theater drops the lock until the next aspect change.
 *
 * ra_vision_arm_aspect_lock() re-sends the CURRENT window size (a no-op resize)
 * with the Uniform restriction.  Idempotent and cheap; safe to call from the
 * SwiftUI root view's onAppear and from the 3D exit path. */
/* The window is not there yet at RARootView.onAppear — measured in the visionOS
 * 27.0 simulator, where the first call produced no beacon line at all while the
 * frontend went on logging "aspect ok 1.778 (win 480x271)" (i.e. 0015's early
 * return, restriction never armed). So retry on the main queue until a window
 * with real bounds exists, then arm once. 20 x 0.25 s is five seconds, an
 * eternity next to a launch and still bounded. */
static void ra_arm_aspect_lock_try(int attempts_left)
{
   if (ra_vision_3d_active())         /* the parked control card stays freeform */
      return;
   /* the 3D-exit restore owns the window until it has re-locked
    * it. Arming here would re-request the PARKED size with Uniform — that is
    * the .44 bug (scenePhase .active fires as the space is dismissed, its
    * request lands after the restore's and wins: card size, card aspect,
    * locked). */
   if (s_windowParked || s_windowRestoring)
   {
      RA_BeaconMark("aspect lock: deferred — the 3D-exit restore re-locks the window");
      return;
   }
   UIWindow *w = [RetroArch_iOS get].window;
   if (!w || w.bounds.size.width < 1.0 || w.bounds.size.height < 1.0)
   {
      if (attempts_left <= 0)
      {
         RA_BeaconMark("aspect lock: no window after 5 s, not armed");
         return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
         ra_arm_aspect_lock_try(attempts_left - 1);
      });
      return;
   }
   {
      char m[96];
      snprintf(m, sizeof m, "aspect lock armed (win %.0fx%.0f a=%.3f)",
               w.bounds.size.width, w.bounds.size.height,
               w.bounds.size.width / w.bounds.size.height);
      RA_BeaconMark(m);
   }
   ra_request_window_size_r(w.bounds.size,
                            UIWindowSceneResizingRestrictionsUniform);
}

void ra_vision_arm_aspect_lock(void)
{
   dispatch_async(dispatch_get_main_queue(), ^{ ra_arm_aspect_lock_try(20); });
}

static void ra_park_window(void)
{
   UIWindow *w = [RetroArch_iOS get].window;
   if (s_windowParked)
      return;
   s_windowRestoring = NO;            /* re-entered 3D mid-restore */
   s_restoreGen++;
   if (w && w.bounds.size.width > 1.0)
      s_savedWindowSize = w.bounds.size;
   s_windowParked = YES;
   {
      char m[96];
      snprintf(m, sizeof m, "window: park, saved %.0fx%.0f", s_savedWindowSize.width,
               s_savedWindowSize.height);
      RA_BeaconMark(m);
   }
   /* ~480pt wide at the screen's aspect, per the settings spec. */
   {
      float a = ra_vision_panel_width() / ra_vision_panel_height();
      if (a < 0.2f || a > 6.0f) a = 16.0f / 9.0f;
      ra_request_window_size_t(CGSizeMake(480.0, round(480.0 / a)),
                               UIWindowSceneResizingRestrictionsFreeform, "park");
   }
}

/* the restore, in two steps. Step 1 asks for the pre-3D size
 * (re-shaped to the content's CURRENT aspect if that changed while in 3D) with
 * FREEFORM, so no restriction can pin the request to the card's aspect. This
 * polls until the window really has that size (re-asking a few times; a
 * request made while the space is still going away can be dropped), and only
 * then step 2 locks Uniform at the size the window actually has — which is
 * the content's aspect, so 0015's lock is back exactly as before 3D. */
static void ra_restore_settle(unsigned gen, CGSize target, int tries)
{
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                  dispatch_get_main_queue(), ^{
      UIWindow *w = [RetroArch_iOS get].window;
      CGSize    cur;
      BOOL      there;
      if (gen != s_restoreGen || !s_windowRestoring || ra_vision_3d_active())
         return;
      if (!w)
      {  /* never leave the aspect lock deferred forever */
         s_windowRestoring = NO;
         RA_BeaconMark("window: restore abandoned — no window");
         return;
      }
      cur   = w.bounds.size;
      there = fabs(cur.width - target.width) <= 2.0 && fabs(cur.height - target.height) <= 2.0;
      if (!there && tries > 0)
      {
         if (tries % 2 == 0)      /* re-ask every 0.8 s */
            ra_request_window_size_t(target, UIWindowSceneResizingRestrictionsFreeform,
                                     "unpark retry");
         ra_restore_settle(gen, target, tries - 1);
         return;
      }
      s_windowRestoring = NO;
      {
         char m[160];
         snprintf(m, sizeof m, "window: restore %s — %.0fx%.0f (wanted %.0fx%.0f), locking uniform",
                  there ? "done" : "GAVE UP", cur.width, cur.height, target.width, target.height);
         RA_BeaconMark(m);
      }
      ra_request_window_size_t(cur, UIWindowSceneResizingRestrictionsUniform, "unpark lock");
   });
}

static void ra_unpark_window(void)
{
   CGSize target;
   float  a;
   if (!s_windowParked)
      return;
   s_windowParked = NO;
   if (s_savedWindowSize.width <= 1.0 || s_savedWindowSize.height <= 1.0)
      return;
   target = s_savedWindowSize;
   /* the window aspect the frontend last asked for (content, or 16:9 with
    * the menu up), rotation applied — it may have changed while in 3D,
    * where 0015 only reshapes the panel */
   a = ra_vision_3d_aspect();
   if (a > 0.2f && a < 6.0f
       && fabs(target.width / target.height - a) / a > 0.02)
      target = CGSizeMake(round(target.height * a), target.height);
   s_windowRestoring = YES;
   s_restoreGen++;
   ra_request_window_size_t(target, UIWindowSceneResizingRestrictionsFreeform, "unpark");
   ra_restore_settle(s_restoreGen, target, 8);   /* <= 3.2 s */
}

/* ------------------------------------------------------------ enter and exit */

/* ------------------------------------------------- run-ahead
 *
 * `runahead = 0|1|2` in system/3dsen/3dsen.cfg (default 0 = off; higher values
 * clamp to 2), read at 3D entry. When it is on, 3D is active and the loaded
 * core is Mesen (exports the RA3D scene stream), RetroArch's own single-
 * instance run-ahead is switched on for the 3D session:
 *   - settings: run_ahead_enabled 1, run_ahead_frames N, secondary instance 0
 *     (the secondary instance copies the core dylib to a temp file, and that
 *     unsigned copy cannot be dlopen'd on a sideloaded visionOS app), hide
 *     warnings 1. IN MEMORY ONLY: RetroArch writes retroarch.cfg only on a
 *     clean quit (config_save_on_exit) or an explicit Save Configuration, and
 *     everything is restored on leaving 3D. Should the app quit mid-3D, the
 *     originals sit in system/3dsen/runahead-restore.cfg and the next launch
 *     puts them back (ra_vision_runahead_heal).
 *   - retro_run is wrapped so the latch in ra3d_runahead.h can tell a hidden
 *     run (VIDEO_FLAG_ACTIVE cleared by runahead.c) from the visible one and
 *     copy only the visible frame for the render thread.
 * A core load memsets current_core, which drops the wrapper; the 10 Hz
 * supervisor below re-wraps it (and re-resolves the latch's symbols). Until
 * then the latch serves no frame, so no hidden frame can leak through. */
#include <dlfcn.h>
#include <time.h>
#include "configuration.h"
#include "runloop.h"
#include "gfx/video_driver.h"

static int   s_ra_knob      = 0;        /* this 3D session's run-ahead frames */
static bool  s_ra_applied   = false;
static bool  s_ra_orig_en, s_ra_orig_sec, s_ra_orig_hide;
static unsigned s_ra_orig_frames;
static void (*s_ra_orig_run)(void) = NULL;
static bool (*s_ra_orig_ser)(void *, size_t) = NULL;
static bool (*s_ra_orig_unser)(const void *, size_t) = NULL;
static void (*s_ra_orig_unload)(void) = NULL;
static bool  s_ra_measure   = false;   /* RA3D_RUNAHEAD_MEASURE: wrap, apply nothing */
static unsigned s_ra_installs = 0;
static bool  s_ra_said_not_mesen = false;
static dispatch_source_t s_ra_timer = nil;

static NSString *ra_ra_sidecar(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   return [docs stringByAppendingPathComponent:
              @"RetroArch/system/3dsen/runahead-restore.cfg"];
}

static void ra_ra_beaconf(const char *fmt, ...)
{
   char buf[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   RA_BeaconMark(buf);
   NSLog(@"[RA3D] %s", buf);
}

/* `runahead` from 3dsen.cfg; exact key, `key = value` lines, # comments. */
static int ra_ra_read_knob(int *raw_out)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *path = [docs stringByAppendingPathComponent:@"RetroArch/system/3dsen/3dsen.cfg"];
   NSString *txt  = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
   int v = 0;
   *raw_out = 0;
   for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
   {
      NSRange eq = [line rangeOfString:@"="];
      NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (eq.location == NSNotFound || [t hasPrefix:@"#"])
         continue;
      NSString *k = [[line substringToIndex:eq.location]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (![k isEqualToString:@"runahead"])
         continue;
      NSString *val = [[[line substringFromIndex:eq.location + 1]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                          stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
      v = atoi(val.UTF8String);        /* a later line wins */
   }
   *raw_out = v;
   return v < 0 ? 0 : (v > 2 ? 2 : v);
}

/* `hands` from 3dsen.cfg, same parsing as `runahead` (exact key,
 * `key = value`, # comments, a later line wins). 0 (default) hides the user's
 * hands and arms over the 3D scene; any other value shows them. */
static int ra_hands_read_knob(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *path = [docs stringByAppendingPathComponent:@"RetroArch/system/3dsen/3dsen.cfg"];
   NSString *txt  = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
   int v = 0;
   for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
   {
      NSRange eq = [line rangeOfString:@"="];
      NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (eq.location == NSNotFound || [t hasPrefix:@"#"])
         continue;
      NSString *k = [[line substringToIndex:eq.location]
                       stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (![k isEqualToString:@"hands"])
         continue;
      NSString *val = [[[line substringFromIndex:eq.location + 1]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                          stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\""]];
      v = atoi(val.UTF8String);
   }
   return v;
}

static double ra_ra_now_ms(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

/* Installed as current_core.retro_run. Main thread, inside runloop_iterate. */
static void ra_ra_run_wrapped(void)
{
   video_driver_state_t *vs = video_state_get_ptr();
   int    hidden = (vs && !(vs->flags & VIDEO_FLAG_ACTIVE)) ? 1 : 0;
   double t0     = ra_ra_now_ms();
   if (s_ra_orig_run)
      s_ra_orig_run();
   ra_vision_latch_after_run(hidden, ra_ra_now_ms() - t0);
}

/* Timing only: runahead.c's save/load go through these (core_serialize_special),
 * outside retro_run, so the run-ahead cost line needs them separately. */
static bool ra_ra_ser_wrapped(void *data, size_t size)
{
   double t0 = ra_ra_now_ms();
   bool ok = s_ra_orig_ser ? s_ra_orig_ser(data, size) : false;
   ra_vision_latch_note_state(0, ra_ra_now_ms() - t0);
   return ok;
}

static bool ra_ra_unser_wrapped(const void *data, size_t size)
{
   double t0 = ra_ra_now_ms();
   bool ok = s_ra_orig_unser ? s_ra_orig_unser(data, size) : false;
   ra_vision_latch_note_state(1, ra_ra_now_ms() - t0);
   return ok;
}

/* Content close: invalidate the latch BEFORE the core unloads, so the render
 * thread can never be handed a frame (or a palette pointer) from it. */
static void ra_ra_unload_wrapped(void)
{
   ra_vision_latch_invalidate();
   if (s_ra_orig_unload)
      s_ra_orig_unload();
}

static void ra_ra_unwrap(void)
{
   runloop_state_t *rs = runloop_state_get_ptr();
   if (rs && rs->current_core.retro_run == ra_ra_run_wrapped)
      rs->current_core.retro_run = s_ra_orig_run;
   if (rs && rs->current_core.retro_serialize == ra_ra_ser_wrapped)
      rs->current_core.retro_serialize = s_ra_orig_ser;
   if (rs && rs->current_core.retro_unserialize == ra_ra_unser_wrapped)
      rs->current_core.retro_unserialize = s_ra_orig_unser;
   if (rs && rs->current_core.retro_unload_game == ra_ra_unload_wrapped)
      rs->current_core.retro_unload_game = s_ra_orig_unload;
   s_ra_orig_run = NULL;
   s_ra_orig_ser = NULL;
   s_ra_orig_unser = NULL;
   s_ra_orig_unload = NULL;
   ra_vision_latch_set(0, NULL, NULL, NULL, 0);
}

static void ra_ra_restore_settings(const char *why)
{
   settings_t *st = config_get_ptr();
   if (!s_ra_applied || !st)
      return;
   st->bools.run_ahead_enabled            = s_ra_orig_en;
   st->uints.run_ahead_frames             = s_ra_orig_frames;
   st->bools.run_ahead_secondary_instance = s_ra_orig_sec;
   st->bools.run_ahead_hide_warnings      = s_ra_orig_hide;
   s_ra_applied = false;
   [NSFileManager.defaultManager removeItemAtPath:ra_ra_sidecar() error:nil];
   ra_ra_beaconf("runahead: restored RetroArch settings (%s) — enabled %d, frames %u, "
                 "secondary instance %d, hide warnings %d; retro_run unwrapped",
                 why, (int)s_ra_orig_en, s_ra_orig_frames, (int)s_ra_orig_sec,
                 (int)s_ra_orig_hide);
}

static void ra_ra_apply_settings(void)
{
   settings_t *st = config_get_ptr();
   if (s_ra_applied || !st)
      return;
   s_ra_orig_en     = st->bools.run_ahead_enabled;
   s_ra_orig_frames = st->uints.run_ahead_frames;
   s_ra_orig_sec    = st->bools.run_ahead_secondary_instance;
   s_ra_orig_hide   = st->bools.run_ahead_hide_warnings;
   {
      NSString *s = [NSString stringWithFormat:
         @"# RetroArch's run-ahead settings before 3D mode turned them on.\n"
          "# Present only while 3D run-ahead is applied; the next launch restores and\n"
          "# deletes it if the app quit mid-3D.\n"
          "enabled=%d\nframes=%u\nsecondary=%d\nhide=%d\n",
         (int)s_ra_orig_en, s_ra_orig_frames, (int)s_ra_orig_sec, (int)s_ra_orig_hide];
      [s writeToFile:ra_ra_sidecar() atomically:YES encoding:NSUTF8StringEncoding error:nil];
   }
   st->bools.run_ahead_enabled            = true;
   st->uints.run_ahead_frames             = (unsigned)s_ra_knob;
   st->bools.run_ahead_secondary_instance = false;
   st->bools.run_ahead_hide_warnings      = true;
   s_ra_applied = true;
   ra_ra_beaconf("runahead: applied — RetroArch run_ahead_enabled 1, frames %d, secondary "
                 "instance 0, hide warnings 1 (was enabled %d, frames %u, secondary %d, "
                 "hide %d; in memory only, restored on leaving 3D)%s",
                 s_ra_knob, (int)s_ra_orig_en, s_ra_orig_frames, (int)s_ra_orig_sec,
                 (int)s_ra_orig_hide,
                 st->bools.preemptive_frames_enable
                    ? " — NOTE preemptive frames is also on; run-ahead takes precedence" : "");
}

/* Main queue, 10 Hz while a run-ahead 3D session is live. */
static void ra_ra_tick(void)
{
   runloop_state_t *rs = runloop_state_get_ptr();
   void *h, *scene, *planes;
   if (!ra_vision_3d_active() || (s_ra_knob <= 0 && !s_ra_measure) || !rs)
      return;
   h      = rs->lib_handle;
   scene  = h ? dlsym(h, "mesen_ra3d_get_scene")  : NULL;
   planes = h ? dlsym(h, "mesen_ra3d_get_planes") : NULL;
   if (!scene || !planes || !rs->current_core.retro_run)
   {
      if (rs->current_core.retro_run == ra_ra_run_wrapped) ra_ra_unwrap();
      if (s_ra_applied)
      {
         ra_vision_latch_set(0, NULL, NULL, NULL, 0);
         ra_ra_restore_settings("core is not Mesen / no core");
      }
      if (!s_ra_said_not_mesen)
      {
         s_ra_said_not_mesen = true;
         ra_ra_beaconf("runahead: %d requested, but the loaded core has no RA3D scene "
                       "stream (not Mesen) — run-ahead not applied", s_ra_knob);
      }
      return;
   }
   s_ra_said_not_mesen = false;
   if (rs->current_core.retro_run != ra_ra_run_wrapped)
   {
      s_ra_orig_run = rs->current_core.retro_run;
      ra_vision_latch_set(1, planes, scene,
                          (void *)rs->current_core.retro_get_memory_data, s_ra_knob);
      rs->current_core.retro_run = ra_ra_run_wrapped;
      if (rs->current_core.retro_serialize && rs->current_core.retro_serialize != ra_ra_ser_wrapped)
      {
         s_ra_orig_ser = rs->current_core.retro_serialize;
         rs->current_core.retro_serialize = ra_ra_ser_wrapped;
      }
      if (rs->current_core.retro_unserialize && rs->current_core.retro_unserialize != ra_ra_unser_wrapped)
      {
         s_ra_orig_unser = rs->current_core.retro_unserialize;
         rs->current_core.retro_unserialize = ra_ra_unser_wrapped;
      }
      if (rs->current_core.retro_unload_game && rs->current_core.retro_unload_game != ra_ra_unload_wrapped)
      {
         s_ra_orig_unload = rs->current_core.retro_unload_game;
         rs->current_core.retro_unload_game = ra_ra_unload_wrapped;
      }
      /* A content load can reload the config (per-core / per-game overrides),
       * which would reset run-ahead under us: re-assert ours. */
      if (s_ra_applied)
      {
         settings_t *st = config_get_ptr();
         if (st && (!st->bools.run_ahead_enabled
                    || st->uints.run_ahead_frames != (unsigned)s_ra_knob
                    || st->bools.run_ahead_secondary_instance))
         {
            st->bools.run_ahead_enabled            = true;
            st->uints.run_ahead_frames             = (unsigned)s_ra_knob;
            st->bools.run_ahead_secondary_instance = false;
            st->bools.run_ahead_hide_warnings      = true;
            ra_ra_beaconf("runahead: settings were reset by a config reload — re-applied");
         }
      }
      s_ra_installs++;
      ra_ra_beaconf("runahead: retro_run wrapped (install %u%s) — the render thread now "
                    "reads only the latched visible frame",
                    s_ra_installs, s_ra_installs > 1 ? ", after a core load" : "");
   }
   if (!s_ra_applied && !s_ra_measure)
      ra_ra_apply_settings();
}

void ra_vision_runahead_begin(void)
{
   int raw = 0;
   s_ra_knob = ra_ra_read_knob(&raw);
   s_ra_installs = 0;
   s_ra_said_not_mesen = false;
   /* Dev hook: wrap and latch with run-ahead OFF, so the beacon's cost
    * line has a same-instrument baseline. Inert unless set; touches no setting. */
   s_ra_measure = (s_ra_knob <= 0 && getenv("RA3D_RUNAHEAD_MEASURE") != NULL);
   if (s_ra_knob <= 0 && !s_ra_measure)
   {
      ra_ra_beaconf("runahead: off (3dsen.cfg runahead = %d) — RetroArch run-ahead "
                    "settings untouched", raw);
      return;
   }
   if (s_ra_measure)
      ra_ra_beaconf("runahead: off, RA3D_RUNAHEAD_MEASURE — wrapping retro_run for the "
                    "cost baseline only; RetroArch settings untouched");
   else
   ra_ra_beaconf("runahead: 3dsen.cfg runahead = %d%s — %d frame%s, single instance, "
                 "applied while 3D is on and the core is Mesen",
                 raw, raw != s_ra_knob ? " (clamped)" : "", s_ra_knob,
                 s_ra_knob == 1 ? "" : "s");
   if (!s_ra_timer)
   {
      s_ra_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                          dispatch_get_main_queue());
      dispatch_source_set_timer(s_ra_timer, DISPATCH_TIME_NOW,
                                100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
      dispatch_source_set_event_handler(s_ra_timer, ^{ ra_ra_tick(); });
      dispatch_resume(s_ra_timer);
   }
}

void ra_vision_runahead_end(void)
{
   if (s_ra_timer)
   {
      dispatch_source_cancel(s_ra_timer);
      s_ra_timer = nil;
   }
   if (s_ra_knob <= 0 && !s_ra_measure)
      return;
   s_ra_measure = false;
   ra_ra_unwrap();
   if (s_ra_applied)
      ra_ra_restore_settings("leaving 3D");
   else
      ra_ra_beaconf("runahead: leaving 3D — nothing was applied");
   s_ra_knob = 0;
}

bool ra_vision_runahead_heal(void)
{
   NSString *txt = [NSString stringWithContentsOfFile:ra_ra_sidecar()
                                             encoding:NSUTF8StringEncoding error:nil];
   settings_t *st = config_get_ptr();
   int en = -1, fr = -1, sec = -1, hide = -1;
   if (!txt || s_ra_applied)
      return true;          /* nothing to heal */
   if (!st)
      return false;         /* config not loaded yet: the caller retries */
   for (NSString *line in [txt componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
   {
      if      ([line hasPrefix:@"enabled="])   en   = atoi([line substringFromIndex:8].UTF8String);
      else if ([line hasPrefix:@"frames="])    fr   = atoi([line substringFromIndex:7].UTF8String);
      else if ([line hasPrefix:@"secondary="]) sec  = atoi([line substringFromIndex:10].UTF8String);
      else if ([line hasPrefix:@"hide="])      hide = atoi([line substringFromIndex:5].UTF8String);
   }
   if (en >= 0)   st->bools.run_ahead_enabled            = en != 0;
   if (fr >= 0)   st->uints.run_ahead_frames             = (unsigned)fr;
   if (sec >= 0)  st->bools.run_ahead_secondary_instance = sec != 0;
   if (hide >= 0) st->bools.run_ahead_hide_warnings      = hide != 0;
   [NSFileManager.defaultManager removeItemAtPath:ra_ra_sidecar() error:nil];
   ra_ra_beaconf("runahead: launch found runahead-restore.cfg (the app quit during 3D "
                 "run-ahead) — RetroArch settings put back: enabled %d, frames %d, "
                 "secondary %d, hide %d", en, fr, sec, hide);
   return true;
}

/* Heal once the config is up: now, or retried every second for 10 s. */
static void ra_ra_heal_retry(int left)
{
   if (ra_vision_runahead_heal() || left <= 0)
      return;
   dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC),
                  dispatch_get_main_queue(), ^{ ra_ra_heal_retry(left - 1); });
}

void ra_vision_3d_begin(void)
{
   if (ra_vision_3d_active())
      return;

   /* Order matters: arm the offscreen redirect BEFORE anything hides or shrinks
    * the window.  A parked/occluded CAMetalLayer stops vending drawables and
    * RetroArch blocks on nextDrawable for pacing — flipping this order hangs
    * the emulator the instant the immersive space opens. */
   atomic_store(&s_active, true);
   NSLog(@"[RA3D] entering 3D: offscreen redirect armed");

   [s_host setCurtainVisible:YES];
   ra_park_window();
   RA_SetAudioFrontStage(true);
   ra_vision_runahead_begin();       /* `runahead` knob */

   /* read before RA_SetImmersiveMode(true) opens the space, so
    * the ImmersiveSpace's upperLimbVisibility is right on this entry. */
   {
      int hands = ra_hands_read_knob();
      ra_ra_beaconf("hands: %s (cfg hands=%d)", hands ? "visible" : "hidden", hands);
      RA_SetHandsHidden(hands == 0);
   }
}

void ra_vision_3d_end(void)
{
   if (!ra_vision_3d_active())
      return;

   atomic_store(&s_active, false);
   ra_vision_runahead_end();         /* restore before anything else */
   ra_vision_offscreen_reset();
   RA_SetAudioFrontStage(false);
   [s_host setCurtainVisible:NO];
   ra_unpark_window();
   /* harness: on device the window's scenePhase returns to
    * .active as the space is dismissed, and RARootView re-arms the aspect
    * lock right then. The simulator never sends that phase change, so
    * RA3D_PHASE_RACE replays it here, at the worst moment. */
   if (getenv("RA3D_PHASE_RACE"))
   {
      RA_BeaconMark("harness: phase race — scenePhase .active re-arm after exit");
      ra_vision_arm_aspect_lock();
   }
   ra_vision_settings_save();
   NSLog(@"[RA3D] left 3D: back on the window (frames composited: %d)", ra_imm_frames);
}

/* Stop the compositor loop and WAIT for it before SwiftUI tears the
 * layerRenderer down — dismissing first leaves the loop touching an object
 * being deallocated. */
static void ra_stop_immersive_and_wait(void)
{
   int spins = 0;
   if (!ra_imm_running)
      return;
   ra_imm_stop = 1;
   while (ra_imm_running && spins < 200)   /* ~2 s ceiling, then give up */
   {
      usleep(10 * 1000);
      spins++;
   }
   if (ra_imm_running)
      NSLog(@"[RA3D] WARNING: render loop did not stop within 2 s");
   ra_imm_stop = 0;
}

/* The ornament's 3D / Exit button. */
void ra_vision_enter_3d(bool on)
{
   if (on)
   {
      if (ra_vision_3d_active())
         return;
      ra_vision_3d_begin();
      RA_SetImmersiveMode(true);     /* Swift opens the space */
   }
   else
   {
      if (!ra_vision_3d_active())
         return;
      ra_stop_immersive_and_wait();
      RA_SetImmersiveMode(false);    /* Swift dismisses, then calls finalize */
   }
}

/* Runs after dismissImmersiveSpace has resolved.  Under mixed immersion the
 * window never deactivates, so this is the authoritative back-to-2D trigger. */
void ra_vision_exit_3d_finalize(void)
{
   ra_vision_3d_end();
}

/* The system dismissed the space (Digital Crown / Home).  The loop saw its
 * layer invalidated and called us on the render thread. */
void ra_vision_immersive_ended(void)
{
   dispatch_async(dispatch_get_main_queue(), ^{
      if (!ra_vision_3d_active())
         return;
      NSLog(@"[RA3D] system dismissed the immersive space — reconciling to 2D");
      RA_SetImmersiveMode(false);
      ra_vision_3d_end();
   });
}

#endif /* RA_VISION_3D */
