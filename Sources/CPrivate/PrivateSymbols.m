#import "CPrivate.h"
#include <dlfcn.h>

// Every private function is resolved once with dlsym. A missing symbol disables the feature
// instead of preventing the app from launching.
static struct {
    int (*dsGetBrightness)(CGDirectDisplayID, float *);
    int (*dsSetBrightness)(CGDirectDisplayID, float);
    bool (*dsCanChangeBrightness)(CGDirectDisplayID);
    int (*dsRegisterBrightness)(CGDirectDisplayID, void *, CFNotificationCallback);
    int (*dsUnregisterBrightness)(CGDirectDisplayID, void *);

    CGError (*slsConfigureDisplayEnabled)(CGDisplayConfigRef, CGDirectDisplayID, bool);
    bool (*slsSupportsHDR)(CGDirectDisplayID);
    bool (*slsIsHDREnabled)(CGDirectDisplayID);
    int (*slsSetHDREnabled)(CGDirectDisplayID, bool);

    CFDictionaryRef (*cdCreateInfo)(CGDirectDisplayID);

    CFTypeRef (*avCreateWithService)(CFAllocatorRef, io_service_t);
    IOReturn (*avReadI2C)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
    IOReturn (*avWriteI2C)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
    IOReturn (*avCopyEDID)(CFTypeRef, CFDataRef *);
} S;

static void EKResolve(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY);
        if (ds) {
            S.dsGetBrightness = dlsym(ds, "DisplayServicesGetBrightness");
            S.dsSetBrightness = dlsym(ds, "DisplayServicesSetBrightness");
            S.dsCanChangeBrightness = dlsym(ds, "DisplayServicesCanChangeBrightness");
            S.dsRegisterBrightness = dlsym(ds, "DisplayServicesRegisterForBrightnessChangeNotifications");
            S.dsUnregisterBrightness = dlsym(ds, "DisplayServicesUnregisterForBrightnessChangeNotifications");
        }
        void *sl = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (sl) {
            S.slsConfigureDisplayEnabled = dlsym(sl, "SLSConfigureDisplayEnabled");
            S.slsSupportsHDR = dlsym(sl, "SLSDisplaySupportsHDRMode");
            S.slsIsHDREnabled = dlsym(sl, "SLSDisplayIsHDRModeEnabled");
            S.slsSetHDREnabled = dlsym(sl, "SLSDisplaySetHDRModeEnabled");
        }
        void *cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY);
        if (cd) {
            S.cdCreateInfo = dlsym(cd, "CoreDisplay_DisplayCreateInfoDictionary");
        }
        void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (io) {
            S.avCreateWithService = dlsym(io, "IOAVServiceCreateWithService");
            S.avReadI2C = dlsym(io, "IOAVServiceReadI2C");
            S.avWriteI2C = dlsym(io, "IOAVServiceWriteI2C");
            S.avCopyEDID = dlsym(io, "IOAVServiceCopyEDID");
        }
    });
}

#pragma mark - DisplayServices

bool EKDSCanChangeBrightness(CGDirectDisplayID display) {
    EKResolve();
    return S.dsCanChangeBrightness && S.dsGetBrightness && S.dsSetBrightness && S.dsCanChangeBrightness(display);
}

bool EKDSGetBrightness(CGDirectDisplayID display, float *value) {
    EKResolve();
    return S.dsGetBrightness && S.dsGetBrightness(display, value) == 0;
}

bool EKDSSetBrightness(CGDirectDisplayID display, float value) {
    EKResolve();
    return S.dsSetBrightness && S.dsSetBrightness(display, value) == 0;
}

static _Atomic(EKBrightnessObserver) gBrightnessObserver;

static void EKBrightnessChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object,
                                CFDictionaryRef userInfo) {
    EKBrightnessObserver callback = gBrightnessObserver;
    if (!callback || !userInfo) return;
    id value = ((__bridge NSDictionary *)userInfo)[@"value"];
    if (![value respondsToSelector:@selector(doubleValue)]) return;
    callback((CGDirectDisplayID)(uintptr_t)observer, [value doubleValue]);
}

bool EKDSAddBrightnessObserver(CGDirectDisplayID display, EKBrightnessObserver observer) {
    EKResolve();
    if (!S.dsRegisterBrightness) return false;
    gBrightnessObserver = observer;
    return S.dsRegisterBrightness(display, (void *)(uintptr_t)display, EKBrightnessChanged) == 0;
}

void EKDSRemoveBrightnessObserver(CGDirectDisplayID display) {
    EKResolve();
    if (S.dsUnregisterBrightness) S.dsUnregisterBrightness(display, (void *)(uintptr_t)display);
}

#pragma mark - SkyLight

bool EKCanConfigureDisplayEnabled(void) {
    EKResolve();
    return S.slsConfigureDisplayEnabled != NULL;
}

CGError EKConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled) {
    EKResolve();
    return S.slsConfigureDisplayEnabled ? S.slsConfigureDisplayEnabled(config, display, enabled) : kCGErrorNotImplemented;
}

bool EKHDRSupported(CGDirectDisplayID display) {
    EKResolve();
    return S.slsSupportsHDR && S.slsIsHDREnabled && S.slsSetHDREnabled && S.slsSupportsHDR(display);
}

bool EKHDREnabled(CGDirectDisplayID display) {
    EKResolve();
    return S.slsIsHDREnabled && S.slsIsHDREnabled(display);
}

bool EKSetHDREnabled(CGDirectDisplayID display, bool enabled) {
    EKResolve();
    return S.slsSetHDREnabled && S.slsSetHDREnabled(display, enabled) == 0;
}

#pragma mark - CoreDisplay

CFDictionaryRef EKCopyDisplayInfo(CGDirectDisplayID display) {
    EKResolve();
    return S.cdCreateInfo ? S.cdCreateInfo(display) : NULL;
}

#pragma mark - IOAVService

CFTypeRef EKAVServiceCreate(io_service_t service) {
    EKResolve();
    return S.avCreateWithService ? S.avCreateWithService(kCFAllocatorDefault, service) : NULL;
}

IOReturn EKAVServiceWriteI2C(CFTypeRef service, uint32_t chipAddress, uint32_t dataAddress, const uint8_t *bytes, uint32_t length) {
    EKResolve();
    return S.avWriteI2C ? S.avWriteI2C(service, chipAddress, dataAddress, (void *)bytes, length) : kIOReturnUnsupported;
}

IOReturn EKAVServiceReadI2C(CFTypeRef service, uint32_t chipAddress, uint32_t offset, uint8_t *bytes, uint32_t length) {
    EKResolve();
    return S.avReadI2C ? S.avReadI2C(service, chipAddress, offset, bytes, length) : kIOReturnUnsupported;
}

CFDataRef EKAVServiceCopyEDID(CFTypeRef service) {
    EKResolve();
    CFDataRef edid = NULL;
    if (!S.avCopyEDID || S.avCopyEDID(service, &edid) != kIOReturnSuccess) return NULL;
    return edid;
}
