#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// A virtual display ("stage") built on the private CGVirtualDisplay API (the same
/// one DeskPad, BetterDisplay and Crisp use). Classes are looked up at runtime, so
/// the app still launches if a future macOS removes them; `+isAvailable` says NO.
/// The display exists while this object is alive and vanishes with the process.
@interface PAVirtualDisplay : NSObject

+ (BOOL)isAvailable;

/// `modes` are point sizes (looks-like size when hiDPI is YES), largest first.
- (nullable instancetype)initWithName:(NSString *)name
                           maxPixels:(CGSize)maxPixels
                               modes:(NSArray<NSValue *> *)modes
                         refreshRate:(double)refreshRate
                               hiDPI:(BOOL)hiDPI;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

@end

NS_ASSUME_NONNULL_END
