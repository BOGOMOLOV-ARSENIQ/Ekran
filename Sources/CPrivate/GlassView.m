#import "CPrivate.h"

NSView *_Nullable EKCreateGlassView(CGFloat cornerRadius) {
    Class glassClass = NSClassFromString(@"NSGlassEffectView");
    if (!glassClass) return nil;
    NSView *view = [[glassClass alloc] initWithFrame:NSZeroRect];
    // Set through KVC so the property does not have to exist in the SDK this is compiled against.
    @try {
        [view setValue:@(cornerRadius) forKey:@"cornerRadius"];
    } @catch (NSException *exception) {
        return nil;
    }
    return view;
}
