#pragma once

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Appearance

/// An NSGlassEffectView (macOS 26 "Liquid Glass") when the system has one, otherwise nil. The class is looked up at
/// runtime so the project still builds against older SDKs.
NSView *_Nullable EKCreateGlassView(CGFloat cornerRadius);

#pragma mark - Virtual displays (private CGVirtualDisplay)

typedef struct {
    uint32_t width;   // framebuffer pixels
    uint32_t height;  // framebuffer pixels
    double refreshRate;
} EKVirtualMode;

typedef struct {
    CGPoint red;
    CGPoint green;
    CGPoint blue;
    CGPoint white;
} EKChromaticity;

/// Owns a CGVirtualDisplay. The display disappears when this object is deallocated.
@interface EKVirtualDisplay : NSObject

+ (BOOL)isSupported;

- (nullable instancetype)initWithName:(NSString *)name
                        maxPixelsWide:(uint32_t)maxPixelsWide
                        maxPixelsHigh:(uint32_t)maxPixelsHigh
                    sizeInMillimeters:(CGSize)sizeInMillimeters
                             vendorID:(uint32_t)vendorID
                            productID:(uint32_t)productID
                         serialNumber:(uint32_t)serialNumber
                         chromaticity:(EKChromaticity)chromaticity
                   terminationHandler:(nullable void (^)(void))terminationHandler NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// With hiDPI enabled every mode W×H also produces a HiDPI mode that looks like W/2×H/2.
- (BOOL)applyModes:(const EKVirtualMode *)modes count:(NSUInteger)count hiDPI:(BOOL)hiDPI;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

@end

#pragma mark - DisplayServices (Apple panels: built-in, Studio Display, Pro Display XDR)

bool EKDSCanChangeBrightness(CGDirectDisplayID display);
bool EKDSGetBrightness(CGDirectDisplayID display, float *value);
bool EKDSSetBrightness(CGDirectDisplayID display, float value);

typedef void (*EKBrightnessObserver)(CGDirectDisplayID display, double value);
/// Event driven: the observer is invoked when the system brightness of the display changes.
bool EKDSAddBrightnessObserver(CGDirectDisplayID display, EKBrightnessObserver observer);
void EKDSRemoveBrightnessObserver(CGDirectDisplayID display);

#pragma mark - SkyLight

bool EKCanConfigureDisplayEnabled(void);
CGError EKConfigureDisplayEnabled(CGDisplayConfigRef config, CGDirectDisplayID display, bool enabled);

bool EKHDRSupported(CGDirectDisplayID display);
bool EKHDREnabled(CGDirectDisplayID display);
bool EKSetHDREnabled(CGDirectDisplayID display, bool enabled);

#pragma mark - CoreDisplay

CFDictionaryRef _Nullable EKCopyDisplayInfo(CGDirectDisplayID display) CF_RETURNS_RETAINED;

#pragma mark - DDC/CI transport

/// Apple silicon: IOAVService for an external DCPAVServiceProxy registry entry.
CFTypeRef _Nullable EKAVServiceCreate(io_service_t service) CF_RETURNS_RETAINED;
IOReturn EKAVServiceWriteI2C(CFTypeRef service, uint32_t chipAddress, uint32_t dataAddress, const uint8_t *bytes, uint32_t length);
IOReturn EKAVServiceReadI2C(CFTypeRef service, uint32_t chipAddress, uint32_t offset, uint8_t *bytes, uint32_t length);
CFDataRef _Nullable EKAVServiceCopyEDID(CFTypeRef service) CF_RETURNS_RETAINED;

/// Intel: IOFramebuffer matching the display (0 when not found). Release with IOObjectRelease.
io_service_t EKIntelFramebufferForDisplay(CGDirectDisplayID display);
/// Intel: one DDC/CI transaction. `send` starts with the 0x51 source byte; pass replyLength 0 for writes.
bool EKIntelDDCRequest(io_service_t framebuffer, const uint8_t *send, uint32_t sendLength, uint8_t *_Nullable reply, uint32_t replyLength);
CFDataRef _Nullable EKIntelCopyEDID(io_service_t framebuffer) CF_RETURNS_RETAINED;

NS_ASSUME_NONNULL_END
