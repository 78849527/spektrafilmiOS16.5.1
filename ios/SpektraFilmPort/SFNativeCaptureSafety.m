#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "Build94LibRawBridge.h"

@implementation SFNativeCaptureSafety

+ (nullable NSString *)startPhotoOutput:(AVCapturePhotoOutput *)output
                               settings:(AVCapturePhotoSettings *)settings
                               delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"AVCapturePhotoOutput rejected RAW request";
        return [NSString stringWithFormat:
            @"RAW 拍摄参数被 AVFoundation 拒绝（%@）：%@；本次未拍照、未回退 JPEG。",
            exception.name ?: @"NSException", reason];
    }
}
@end
