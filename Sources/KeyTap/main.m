// Ekran Keys — the only part of Ekran that needs the Accessibility permission (for the media key event tap).
//
// macOS binds that permission to the exact code signature of the process that creates the tap. Keeping the tap in
// this small helper, which build.sh compiles once and caches, lets Ekran itself be rebuilt without the user having
// to grant the permission again. The helper decides synchronously whether a key belongs to Ekran (from the state
// Ekran sends), swallows it and reports the press back, so it never holds an input event while waiting for Ekran.

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

static NSString *const StateNotification = @"app.ekran.keytap.state";      // Ekran -> helper
static NSString *const CommandNotification = @"app.ekran.keytap.command";  // Ekran -> helper
static NSString *const PressNotification = @"app.ekran.keytap.press";      // helper -> Ekran
static NSString *const StatusNotification = @"app.ekran.keytap.status";    // helper -> Ekran

enum { KeySoundUp = 0, KeySoundDown = 1, KeyBrightnessUp = 2, KeyBrightnessDown = 3, KeyMute = 7 };
enum { TargetMouse = 0, TargetMain = 1, TargetAll = 2 };
static const CGEventType SystemDefinedEvent = 14;  // NX_SYSDEFINED
static const short AuxControlButtons = 8;          // NX_SUBTYPE_AUX_CONTROL_BUTTONS

static NSString *token;
static CFMachPortRef tap;
static CFRunLoopSourceRef tapSource;
static dispatch_queue_t postQueue;
static dispatch_source_t parentExit;
static NSTimer *trustTimer;

// State sent by Ekran. Only touched on the main thread, which runs nothing but the tap and these updates.
static bool enabled;
static bool handlesVolume;
static int target = TargetMouse;
static NSSet<NSNumber *> *displays;

static void post(NSString *name, NSDictionary *info) {
    dispatch_async(postQueue, ^{
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:name object:token userInfo:info deliverImmediately:YES];
    });
}

static void postStatus(void) {
    post(StatusNotification, @{@"trusted": @(AXIsProcessTrusted()), @"tap": @(tap != NULL)});
}

static bool consumes(int key, CGPoint location) {
    if (!enabled) return false;
    switch (key) {
        case KeyBrightnessUp:
        case KeyBrightnessDown: {
            if (displays.count == 0) return false;
            if (target == TargetAll) return true;
            CGDirectDisplayID display = kCGNullDirectDisplay;
            if (target == TargetMain) {
                display = CGMainDisplayID();
            } else {
                uint32_t count = 0;
                if (CGGetDisplaysWithPoint(location, 1, &display, &count) != kCGErrorSuccess || count == 0) return false;
            }
            return [displays containsObject:@(display)];
        }
        case KeySoundUp:
        case KeySoundDown:
        case KeyMute:
            return handlesVolume;
        default:
            return false;
    }
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (tap) CGEventTapEnable(tap, true);
        return event;
    }
    if (type != SystemDefinedEvent) return event;
    @autoreleasepool {
        // Mouse button changes arrive as system-defined events too; only media keys are inspected further.
        NSEvent *systemEvent = [NSEvent eventWithCGEvent:event];
        if (systemEvent.subtype != AuxControlButtons) return event;
        NSInteger data = systemEvent.data1;
        int key = (int)((data & 0xFFFF0000) >> 16);
        bool down = ((data & 0xFF00) >> 8) == 0x0A;
        if (!consumes(key, CGEventGetLocation(event))) return event;
        if (down) {
            CGEventFlags flags = CGEventGetFlags(event);
            bool fine = (flags & kCGEventFlagMaskAlternate) && (flags & kCGEventFlagMaskShift);
            post(PressNotification, @{@"key": @(key), @"fine": @(fine)});
        }
        return NULL;
    }
}

static void installTap(void) {
    if (tap) return;
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                           CGEventMaskBit(SystemDefinedEvent), tapCallback, NULL);
    if (!tap) return;
    tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);
}

static void removeTap(void) {
    if (!tap) return;
    CGEventTapEnable(tap, false);
    CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, kCFRunLoopCommonModes);
    CFRelease(tapSource);
    CFMachPortInvalidate(tap);
    CFRelease(tap);
    tapSource = NULL;
    tap = NULL;
}

/// The tap exists only while Ekran needs it and the permission is granted.
static void update(void) {
    bool trusted = AXIsProcessTrusted();
    if (enabled && trusted) {
        installTap();
    } else {
        removeTap();
    }
    if (trusted) {
        [trustTimer invalidate];
        trustTimer = nil;
    }
    postStatus();
}

/// After asking for the permission, check for a while whether the user granted it.
static void watchTrust(void) {
    [trustTimer invalidate];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:600];
    trustTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *timer) {
        if (AXIsProcessTrusted() || [deadline timeIntervalSinceNow] < 0) {
            [timer invalidate];
            trustTimer = nil;
            update();
        }
    }];
    trustTimer.tolerance = 0.5;
}

static void requestPermission(void) {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    watchTrust();
    postStatus();
}

@interface Observer : NSObject
@end

@implementation Observer

- (void)state:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    enabled = [info[@"enabled"] boolValue];
    handlesVolume = [info[@"volume"] boolValue];
    target = [info[@"target"] intValue];
    NSArray *list = [info[@"displays"] isKindOfClass:NSArray.class] ? info[@"displays"] : @[];
    displays = [NSSet setWithArray:list];
    update();
}

- (void)command:(NSNotification *)note {
    NSString *command = note.userInfo[@"command"];
    if ([command isEqualToString:@"prompt"]) {
        requestPermission();
    } else if ([command isEqualToString:@"check"]) {
        update();
    } else if ([command isEqualToString:@"quit"]) {
        removeTap();
        exit(0);
    }
}

- (void)accessibilityChanged:(NSNotification *)note {
    // The trust database is written slightly after the notification.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ update(); });
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        pid_t parent = 0;
        bool prompt = false;
        NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
        for (NSUInteger i = 1; i < arguments.count; i++) {
            if ([arguments[i] isEqualToString:@"--parent"] && i + 1 < arguments.count) {
                parent = (pid_t)arguments[++i].intValue;
            } else if ([arguments[i] isEqualToString:@"--token"] && i + 1 < arguments.count) {
                token = arguments[++i];
            } else if ([arguments[i] isEqualToString:@"--prompt"]) {
                prompt = true;
            }
        }
        // Only Ekran starts the helper, and the helper never outlives it.
        if (parent <= 0 || token.length == 0 || kill(parent, 0) != 0) return 0;

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyProhibited;
        postQueue = dispatch_queue_create("app.ekran.keytap.post", DISPATCH_QUEUE_SERIAL);

        parentExit = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(parentExit, ^{
            removeTap();
            exit(0);
        });
        dispatch_resume(parentExit);

        // Background apps have distributed notification delivery suspended, so observers must opt out of that.
        Observer *observer = [Observer new];
        NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
        [center addObserver:observer selector:@selector(state:) name:StateNotification object:token
         suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        [center addObserver:observer selector:@selector(command:) name:CommandNotification object:token
         suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
        [center addObserver:observer selector:@selector(accessibilityChanged:) name:@"com.apple.accessibility.api" object:nil
         suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];

        if (prompt) {
            requestPermission();
        } else {
            postStatus();
        }
        [NSApp run];
    }
    return 0;
}
