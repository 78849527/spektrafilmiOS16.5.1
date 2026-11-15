#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Build94 explicit LibRaw/DCraw compatibility output. RGB8 is intentional:
/// this is NOT the Python Float64/scene-linear original RAW path.
@interface SFBuild94RawResult : NSObject
@property (nonatomic, readonly) NSData *rgb8;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSString *decoder;
- (instancetype)initWithRGB8:(NSData *)rgb8
                        width:(NSInteger)width
                       height:(NSInteger)height
                      decoder:(NSString *)decoder;
@end

@interface SFBuild94LibRaw : NSObject
+ (nullable SFBuild94RawResult *)decodeURL:(NSURL *)url
                                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(decode(_:));
@end
NS_ASSUME_NONNULL_END
