/* RAVisionOffscreen.m — the offscreen frame ring behind 3D theater mode.
 *
 * RetroArch's Metal driver ends every frame by acquiring a CAMetalDrawable from
 * the window's CAMetalLayer and rendering the whole composite into its texture.
 * That single choke point (Context.nextDrawable) is where we redirect: while 3D
 * is active it hands back an RAOffscreenDrawable instead — a minimal
 * CAMetalDrawable conformer wrapping one of three app-owned textures.  Nothing
 * else in the driver changes, so what lands in our texture is byte-for-byte
 * what the 2D window would have shown: core video, shader chain, menu, OSD.
 *
 * Why redirect at all instead of copying out of the window's drawable: on
 * visionOS a window that has been parked/hidden behind an open ImmersiveSpace
 * stops vending drawables, and RetroArch BLOCKS on nextDrawable for pacing —
 * the engine would hang the moment the space opened.  Rendering offscreen is
 * the guide's "put the engine offscreen BEFORE the space opens" rule, and it is
 * load-bearing, not an optimisation.
 *
 * Ownership / synchronisation:
 *   - RetroArch (main thread + its Metal queue) writes slot `w`.
 *   - publish() runs from the frame command buffer's COMPLETED handler, so a
 *     slot only becomes visible after the GPU is done with it.
 *   - The compositor thread borrows the newest published slot for the duration
 *     of one composited frame; acquire() never hands out the borrowed slot nor
 *     the newest published one, so a three-slot ring is always tear-free.
 */

#import "RAVision.h"

#if defined(RA_VISION_3D)

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <stdatomic.h>

#define RA_RING 3

/* ------------------------------------------------------------------ drawable */

/* A CAMetalDrawable that presents to nobody.  RetroArch only ever touches
 * .texture and -present, but the protocol has to be satisfied in full or the
 * compiler (rightly) complains. */
@interface RAOffscreenDrawable : NSObject <CAMetalDrawable>
@property (nonatomic, strong) id<MTLTexture> texture;
@property (nonatomic, assign) NSInteger      slot;
@end

@implementation RAOffscreenDrawable
- (CAMetalLayer *)layer                                    { return nil; }
- (NSUInteger)drawableID                                   { return (NSUInteger)_slot; }
- (CFTimeInterval)presentedTime                            { return 0.0; }
- (void)present                                            { }
- (void)presentAtTime:(CFTimeInterval)t                    { (void)t; }
- (void)presentAfterMinimumDuration:(CFTimeInterval)d      { (void)d; }
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)b { (void)b; }
@end

/* ---------------------------------------------------------------------- ring */

static id<MTLTexture>        s_tex[RA_RING];
static RAOffscreenDrawable  *s_current;   /* keeps this frame's stand-in alive */
static NSLock               *s_lock;
static int                   s_borrowSlot = -1;  /* diagnostics only */

static _Atomic int     s_latest   = -1;   /* newest slot the GPU has finished  */
/* Per-slot borrow count rather than a single "held" index: the compositor
 * releases slot N from N's command-buffer completion handler, which can land
 * AFTER the loop has already borrowed N+1.  A single index would be cleared by
 * the late release and hand N+1 straight back to the emulator mid-sample. */
static _Atomic int     s_inflight[RA_RING];
static _Atomic int     s_credits  = 0;    /* bounded pacing credits            */
static dispatch_semaphore_t s_pace;

static unsigned        s_w, s_h;
static MTLPixelFormat  s_fmt = MTLPixelFormatInvalid;

static void ra_ring_init_once(void)
{
   static dispatch_once_t once;
   dispatch_once(&once, ^{
      s_lock = [NSLock new];
      s_pace = dispatch_semaphore_create(0);
   });
}

/* Allocate (or re-allocate) the ring.  Called with s_lock held. */
static void ra_ring_alloc(id<MTLDevice> dev, MTLPixelFormat fmt, unsigned w, unsigned h)
{
   int i;
   MTLTextureDescriptor *td =
      [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fmt
                                                         width:w
                                                        height:h
                                                     mipmapped:YES];
   /* RenderTarget: RetroArch draws into it.  ShaderRead: the panel samples it.
    * mipmapped + RenderTarget together are what let the compositor thread run
    * generateMipmaps in place — the single biggest apparent-sharpness lever on
    * a panel that downsamples a 3840-wide image onto ~1400 px of retina
    * (guide 2.6 #1). */
   td.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   td.storageMode = MTLStorageModePrivate;

   for (i = 0; i < RA_RING; i++)
   {
      s_tex[i] = [dev newTextureWithDescriptor:td];
      s_tex[i].label = [NSString stringWithFormat:@"RA 3D frame ring %d", i];
   }
   s_w   = w;
   s_h   = h;
   s_fmt = fmt;
   atomic_store(&s_latest, -1);
   for (i = 0; i < RA_RING; i++)
      atomic_store(&s_inflight[i], 0);
   NSLog(@"[RA3D] frame ring: %d x %ux%u fmt=%lu", RA_RING, w, h, (unsigned long)fmt);
}

void *ra_vision_offscreen_acquire(void *device, unsigned pixel_format, int *out_slot)
{
   unsigned w = 0, h = 0;
   int i, slot = -1, latest;
   id<MTLDevice> dev = (__bridge id<MTLDevice>)device;
   MTLPixelFormat fmt = (MTLPixelFormat)pixel_format;

   if (out_slot)
      *out_slot = -1;
   if (!dev)
      return NULL;

   ra_ring_init_once();
   ra_vision_3d_render_size(&w, &h);
   if (w < 16 || h < 16)
      return NULL;

   /* Pace to the compositor.  Credits are bounded at RA_RING, so a compositor
    * running faster than the core can never bank enough to disable pacing
    * later, and the timeout means a stopped compositor just degrades to
    * free-running instead of deadlocking the emulator. */
   if (dispatch_semaphore_wait(s_pace,
          dispatch_time(DISPATCH_TIME_NOW, (int64_t)(34 * NSEC_PER_MSEC))) == 0)
      atomic_fetch_sub(&s_credits, 1);

   [s_lock lock];
   if (!s_tex[0] || s_w != w || s_h != h || s_fmt != fmt)
      ra_ring_alloc(dev, fmt, w, h);

   /* Prefer a slot that is neither the newest published frame (the compositor
    * is about to want it) nor still being sampled. */
   latest = atomic_load(&s_latest);
   for (i = 0; i < RA_RING; i++)
   {
      if (i != latest && atomic_load(&s_inflight[i]) == 0)
      {
         slot = i;
         break;
      }
   }
   if (slot < 0)
   {
      /* Everything else is in flight: take the newest published frame rather
       * than overwrite one the compositor is mid-sample on.  Worst case the
       * panel shows one torn frame; it never reads a texture out from under
       * the GPU, and it never blocks the emulator. */
      for (i = 0; i < RA_RING; i++)
         if (atomic_load(&s_inflight[i]) == 0)
            { slot = i; break; }
   }
   if (slot < 0)
      slot = (latest >= 0) ? latest : 0;

   RAOffscreenDrawable *d = [RAOffscreenDrawable new];
   d.texture = s_tex[slot];
   d.slot    = slot;
   s_current = d;               /* the ring owns it; metal.m borrows */
   [s_lock unlock];

   if (out_slot)
      *out_slot = slot;
   return (__bridge void *)d;
}

void ra_vision_offscreen_publish(int slot)
{
   if (slot >= 0 && slot < RA_RING)
      atomic_store(&s_latest, slot);
}

void *ra_vision_offscreen_borrow_latest(void)
{
   int latest;
   id<MTLTexture> t = nil;

   ra_ring_init_once();
   [s_lock lock];
   latest = atomic_load(&s_latest);
   if (latest >= 0 && latest < RA_RING)
   {
      t = s_tex[latest];
      atomic_fetch_add(&s_inflight[latest], 1);
      s_borrowSlot = latest;
   }
   [s_lock unlock];

   return t ? (void *)CFBridgingRetain(t) : NULL;
}

void ra_vision_offscreen_release(void *texture)
{
   int i;
   id<MTLTexture> t;
   if (!texture)
      return;
   t = (id<MTLTexture>)CFBridgingRelease(texture);
   /* Decrement the slot this texture actually belongs to — identity, not a
    * remembered index, so an out-of-order release still lands on the right one. */
   for (i = 0; i < RA_RING; i++)
   {
      if (s_tex[i] == t)
      {
         if (atomic_load(&s_inflight[i]) > 0)
            atomic_fetch_sub(&s_inflight[i], 1);
         break;
      }
   }
}

void ra_vision_offscreen_credit(void)
{
   ra_ring_init_once();
   if (atomic_load(&s_credits) < RA_RING)
   {
      atomic_fetch_add(&s_credits, 1);
      dispatch_semaphore_signal(s_pace);
   }
}

void ra_vision_offscreen_reset(void)
{
   int i;
   ra_ring_init_once();
   [s_lock lock];
   for (i = 0; i < RA_RING; i++)
      s_tex[i] = nil;
   s_current = nil;
   s_w = s_h = 0;
   s_fmt = MTLPixelFormatInvalid;
   atomic_store(&s_latest, -1);
   for (i = 0; i < RA_RING; i++)
      atomic_store(&s_inflight[i], 0);
   [s_lock unlock];

   /* Drain banked credits so the next entry starts paced, not free-running. */
   while (atomic_load(&s_credits) > 0)
   {
      if (dispatch_semaphore_wait(s_pace, DISPATCH_TIME_NOW) != 0)
         break;
      atomic_fetch_sub(&s_credits, 1);
   }
}

#endif /* RA_VISION_3D */
