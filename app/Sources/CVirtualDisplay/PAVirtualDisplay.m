#import "PAVirtualDisplay.h"

// Private CoreGraphics interfaces (from DeskPad's CGVirtualDisplayPrivate.h and the
// macOS 26.4 header dump). Declared for typing only: classes are always obtained
// with NSClassFromString, so no symbol is linked.
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic) void (^terminationHandler)(id, id);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@end

@implementation PAVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (BOOL)isAvailable {
    return NSClassFromString(@"CGVirtualDisplay") && NSClassFromString(@"CGVirtualDisplayDescriptor")
        && NSClassFromString(@"CGVirtualDisplaySettings") && NSClassFromString(@"CGVirtualDisplayMode");
}

- (instancetype)initWithName:(NSString *)name
                   maxPixels:(CGSize)maxPixels
                       modes:(NSArray<NSValue *> *)modes
                 refreshRate:(double)refreshRate
                       hiDPI:(BOOL)hiDPI {
    if (!(self = [super init]) || ![PAVirtualDisplay isAvailable] || modes.count == 0) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = (unsigned int)maxPixels.width;
    descriptor.maxPixelsHigh = (unsigned int)maxPixels.height;
    // ~220 ppi (Retina-like), so macOS treats the HiDPI modes as native.
    descriptor.sizeInMillimeters = CGSizeMake(maxPixels.width / 220.0 * 25.4, maxPixels.height / 220.0 * 25.4);
    // vendorID must be non-zero or init returns nil. A stable identity lets macOS
    // remember the arrangement instead of treating each launch as a new monitor.
    descriptor.vendorID = 0x5041;   // "PA"
    descriptor.productID = 0x5354;  // "ST"
    descriptor.serialNum = 1;
    descriptor.terminationHandler = ^(id a, id b) {};

    CGVirtualDisplay *display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) return nil;

    NSMutableArray *displayModes = [NSMutableArray array];
    for (NSValue *value in modes) {
        CGSize size = value.sizeValue;
        [displayModes addObject:[[NSClassFromString(@"CGVirtualDisplayMode") alloc]
                                    initWithWidth:(NSUInteger)size.width height:(NSUInteger)size.height refreshRate:refreshRate]];
    }
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.hiDPI = hiDPI ? 1 : 0;
    settings.modes = displayModes;
    if (![display applySettings:settings]) return nil;

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
