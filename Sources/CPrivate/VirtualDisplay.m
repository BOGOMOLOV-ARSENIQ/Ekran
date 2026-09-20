#import "CPrivate.h"

// Private CoreGraphics classes. They are resolved with NSClassFromString so the app still
// launches (with the feature disabled) on a system where they are missing.

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

@implementation EKVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isSupported {
    static BOOL supported;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        supported = NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor") &&
                    NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
    });
    return supported;
}

- (instancetype)initWithName:(NSString *)name
               maxPixelsWide:(uint32_t)maxPixelsWide
               maxPixelsHigh:(uint32_t)maxPixelsHigh
           sizeInMillimeters:(CGSize)sizeInMillimeters
                    vendorID:(uint32_t)vendorID
                   productID:(uint32_t)productID
                serialNumber:(uint32_t)serialNumber
                chromaticity:(EKChromaticity)chromaticity
          terminationHandler:(void (^)(void))terminationHandler {
    if (![EKVirtualDisplay isSupported]) return nil;
    if (!(self = [super init])) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = maxPixelsWide;
    descriptor.maxPixelsHigh = maxPixelsHigh;
    descriptor.sizeInMillimeters = sizeInMillimeters;
    descriptor.vendorID = vendorID;
    descriptor.productID = productID;
    descriptor.serialNum = serialNumber;
    descriptor.redPrimary = chromaticity.red;
    descriptor.greenPrimary = chromaticity.green;
    descriptor.bluePrimary = chromaticity.blue;
    descriptor.whitePoint = chromaticity.white;
    if (terminationHandler) {
        void (^handler)(void) = [terminationHandler copy];
        descriptor.terminationHandler = ^(id __unused sender, id __unused display) { handler(); };
    }

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!_display || _display.displayID == kCGNullDirectDisplay) return nil;
    return self;
}

- (BOOL)applyModes:(const EKVirtualMode *)modes count:(NSUInteger)count hiDPI:(BOOL)hiDPI {
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) {
        CGVirtualDisplayMode *mode = [[modeClass alloc] initWithWidth:modes[i].width
                                                               height:modes[i].height
                                                          refreshRate:modes[i].refreshRate];
        if (mode) [list addObject:mode];
    }
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = list;
    return [_display applySettings:settings];
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
