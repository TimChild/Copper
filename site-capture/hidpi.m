// Capture shim: makes this one Copper process render as it does on a Retina
// display (backing scale 2), so WindowServer pictures carry real 2x pixels.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
@interface NSWindow (P) - (void)_setBackingScaleFactor:(CGFloat)s; @end
static CGFloat two(id self, SEL _cmd) { return 2.0; }
static BOOL yes1(id self, SEL _cmd, NSInteger arg) { return YES; }
static void force(void) {
  for (NSWindow *w in NSApp.windows) {
    if (w.backingScaleFactor != 2.0 && [w respondsToSelector:@selector(_setBackingScaleFactor:)]) {
      ((void (*)(id, SEL, CGFloat))objc_msgSend)(w, @selector(_setBackingScaleFactor:), 2.0);
    }
    if (getenv("COPPER_SHOOT_ACTIVE") && [w respondsToSelector:NSSelectorFromString(@"_setForceActiveControls:")]) {
      ((void (*)(id, SEL, BOOL))objc_msgSend)(w, NSSelectorFromString(@"_setForceActiveControls:"), YES);
    }
  }
}
__attribute__((constructor)) static void init(void) {
  Method m = class_getInstanceMethod([NSScreen class], @selector(backingScaleFactor));
  method_setImplementation(m, (IMP)two);
  if (getenv("COPPER_SHOOT_ACTIVE")) {
    Method a = class_getInstanceMethod([NSWindow class], NSSelectorFromString(@"_hasActiveAppearanceForStandardWindowButton:"));
    if (a) method_setImplementation(a, (IMP)yes1);
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { force(); }];
  });
  fprintf(stderr, "hidpi shim loaded\n");
}
