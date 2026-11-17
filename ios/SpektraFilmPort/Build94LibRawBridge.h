#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Build94 explicit LibRaw/DCraw compatibility output. RGB8 is intentional:
/// this is NOT the Python Float64/scene-linear original RAW path.
@interface SFBuild94RawResult : NSObject
/// Raw LibRaw dcraw RGB samples, 8 or 16 bits per channel. The original
/// rgb8 selector is kept as API compatibility; inspect bitsPerComponent.
@property (nonatomic, readonly) NSData *rgb8;
@property (nonatomic, readonly) NSInteger bitsPerComponent;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSString *decoder;
- (instancetype)initWithRGB8:(NSData *)rgb8
                        width:(NSInteger)width
                       height:(NSInteger)height
                      decoder:(NSString *)decoder;
- (instancetype)initWithPixels:(NSData *)pixels
               bitsPerComponent:(NSInteger)bits
                          width:(NSInteger)width
                         height:(NSInteger)height
                        decoder:(NSString *)decoder;
@end

@interface SFBuild94LibRaw : NSObject
+ (nullable SFBuild94RawResult *)decodeURL:(NSURL *)url
                                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(decode(_:));
+ (nullable SFBuild94RawResult *)decodeURL:(NSURL *)url
                          bitsPerComponent:(NSInteger)bits
                                     error:(NSError * _Nullable * _Nullable)error
    NS_SWIFT_NAME(decode(_:bitsPerComponent:));
@end

/// Build123: Objective-C AVFoundation immediate settings-validation guard.
/// capturePhoto(with:delegate:) may raise NSInvalidArgumentException rather
/// than return a Swift Error when the RAW settings combination is illegal.
/// This wrapper catches ONLY the synchronous call. It cannot catch
/// asynchronous camera-process or iOS Jetsam crashes; those remain explicit.
@class AVCapturePhotoOutput, AVCapturePhotoSettings;
@protocol AVCapturePhotoCaptureDelegate;
@interface SFNativeCaptureSafety : NSObject
/// Nil means the request was submitted. Non-nil describes the validation
/// exception and MUST be surfaced, never downgraded to JPEG.
+ (nullable NSString *)startPhotoOutput:(AVCapturePhotoOutput *)output
                               settings:(AVCapturePhotoSettings *)settings
                               delegate:(id<AVCapturePhotoCaptureDelegate>)delegate
    NS_SWIFT_NAME(startPhotoOutput(_:settings:delegate:));
@end
NS_ASSUME_NONNULL_END
