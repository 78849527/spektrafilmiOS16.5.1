#import "Build94LibRawBridge.h"
#include "libraw/libraw.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#include <os/proc.h>
#endif
#endif

static NSString * const SFBuild94Domain = @"SpektraFilm.LibRaw.Build94";

static void SFBuild94Fail(NSError **outError, NSInteger code, NSString *message) {
    if (outError != NULL) {
        *outError = [NSError errorWithDomain:SFBuild94Domain
                                       code:code
                                   userInfo:@{NSLocalizedDescriptionKey: message}];
    }
}

@implementation SFBuild94RawResult
- (instancetype)initWithRGB8:(NSData *)rgb8
                        width:(NSInteger)width
                       height:(NSInteger)height
                      decoder:(NSString *)decoder {
    self = [super init];
    if (self) {
        _rgb8 = rgb8;
        _width = width;
        _height = height;
        _decoder = [decoder copy];
    }
    _bitsPerComponent = 8;
    return self;
}
- (instancetype)initWithPixels:(NSData *)pixels
               bitsPerComponent:(NSInteger)bits
                          width:(NSInteger)width
                         height:(NSInteger)height
                        decoder:(NSString *)decoder {
    self = [self initWithRGB8:pixels width:width height:height decoder:decoder];
    if (self) _bitsPerComponent = bits;
    return self;
}
@end

@implementation SFBuild94LibRaw
+ (SFBuild94RawResult *)decodeURL:(NSURL *)url error:(NSError **)error {
    return [self decodeURL:url bitsPerComponent:8 error:error];
}
+ (SFBuild94RawResult *)decodeURL:(NSURL *)url
                 bitsPerComponent:(NSInteger)bits
                            error:(NSError **)error {
    return [self decodeURL:url
          bitsPerComponent:bits
         sourceLinearACES:NO
                    error:error];
}
+ (SFBuild94RawResult *)decodeURL:(NSURL *)url
                 bitsPerComponent:(NSInteger)bits
                sourceLinearACES:(BOOL)sourceLinearACES
                           error:(NSError **)error {
    if (bits != 8 && bits != 16) {
        SFBuild94Fail(error, 6, @"LibRaw 解码位深仅支持显式 8 或 16 bit");
        return nil;
    }
    if (sourceLinearACES && bits != 16) {
        SFBuild94Fail(error, 9, @"原版 RAW 入口必须使用 16-bit 线性 ACES，禁止降为 RGB8");
        return nil;
    }
    // Fail closed: caller has already verified RAF signature and preserved
    // the original bytes; no embedded thumbnail, no Apple/JPEG fallback.
    if (url == nil || !url.isFileURL) {
        SFBuild94Fail(error, 1, @"LibRaw 仅允许已保存的本地 RAW 文件");
        return nil;
    }
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        SFBuild94Fail(error, 2, @"LibRaw 初始化失败或内存不足");
        return nil;
    }
    SFBuild94RawResult *result = nil;
    libraw_processed_image_t *image = NULL;
    do {
        int rc = libraw_open_file(raw, url.fileSystemRepresentation);
        if (rc != LIBRAW_SUCCESS) {
            SFBuild94Fail(error, rc, [NSString stringWithFormat:
                @"LibRaw 无法打开 RAW：%s", libraw_strerror(rc)]);
            break;
        }
        const uint64_t w = (uint64_t)raw->sizes.width;
        const uint64_t h = (uint64_t)raw->sizes.height;
        // Explicit limit: avoid accidental multi-gigabyte 40MP+ allocations.
        if (!w || !h || w > 10000 || h > 10000 ||
            w > UINT64_MAX / h || w * h > 45000000) {
            SFBuild94Fail(error, 3,
                @"LibRaw 源图超出目前 4500 万像素解码上限；原始 RAF 已保留");
            break;
        }
        // Conservative pre-unpack memory admission gate. 40MP/16-bit
        // estimates 1216MB; a failed admission NEVER silently switches to
        // 8-bit or to the RAF embedded JPEG.
        const uint64_t pixels = w * h;
        const uint64_t estimatedBytes =
            pixels * (bits == 16 ? 28ull : 18ull) + 96000000ull;
        if (estimatedBytes > 1400000000ull) {
            SFBuild94Fail(error, 7, [NSString stringWithFormat:
                @"LibRaw %@-bit 估算内存 %.0f MB 超过 1400 MB 上限；原始 RAF 保留",
                @(bits), (double)estimatedBytes / 1000000.0]);
            break;
        }
        // Build96: genuine iPhoneOS process headroom admission BEFORE
        // LibRaw allocates full X-Trans sensor, RGB, and temporary images.
        // This is advisory; never promise jetsam-free 40MP processing.
#if defined(__APPLE__) && TARGET_OS_IPHONE
        const uint64_t headroom = (uint64_t)os_proc_available_memory();
        if (!headroom || estimatedBytes > (headroom / 100ull) * 70ull) {
            SFBuild94Fail(error, 8, [NSString stringWithFormat:
                @"LibRaw %@-bit: iPhone 当前可用内存 %.0f MB，预估需 %.0f MB；禁止在高风险内存下启动 RAW 解包；请换更空闲设备或在相机改小 RAW 规格",
                @(bits), (double)headroom / 1000000.0,
                (double)estimatedBytes / 1000000.0]);
            break;
        }
#endif
        // Original Python raw_file_processor._postprocess_params('as_shot'):
        // output_color=rawpy.ColorSpace.ACES (LibRaw 6), output_bps=16,
        // no_auto_bright=True, gamma=(1,1), use_camera_wb=True.
        // Default source branch is camera WB; other WB/tint/lens branches
        // remain unported and MUST NOT be called numerically equivalent.
        // Explicit legacy fast branch retains its old sRGB and gamma settings.
        // UInt16 output is native-endian on iPhoneOS arm64 (little-endian).
        libraw_set_output_bps(raw, (int)bits);
        libraw_set_output_color(raw, sourceLinearACES ? 6 : 1);
        libraw_set_no_auto_bright(raw, 1);
        if (sourceLinearACES) {
            raw->params.gamm[0] = 1.0;
            raw->params.gamm[1] = 1.0;
        }
        raw->params.use_camera_wb = 1;
        raw->params.use_auto_wb = 0;
        raw->params.half_size = 0;
        rc = libraw_unpack(raw);
        if (rc != LIBRAW_SUCCESS) {
            SFBuild94Fail(error, rc, [NSString stringWithFormat:
                @"LibRaw 真实传感器解包失败：%s", libraw_strerror(rc)]);
            break;
        }
        rc = libraw_dcraw_process(raw);
        if (rc != LIBRAW_SUCCESS) {
            SFBuild94Fail(error, rc, [NSString stringWithFormat:
                @"LibRaw X-Trans 去马赛克失败：%s", libraw_strerror(rc)]);
            break;
        }
        int memError = 0;
        image = libraw_dcraw_make_mem_image(raw, &memError);
        if (!image || memError != LIBRAW_SUCCESS) {
            SFBuild94Fail(error, memError, @"LibRaw 传感器 RGB 数据导出失败");
            break;
        }
        const uint64_t required = (uint64_t)image->width *
            (uint64_t)image->height * 3u * (uint64_t)(bits / 8);
        if (image->type != LIBRAW_IMAGE_BITMAP ||
            image->bits != (unsigned)bits ||
            image->colors != 3 || image->width == 0 || image->height == 0 ||
            (uint64_t)image->width * (uint64_t)image->height > 45000000 ||
            required != (uint64_t)image->data_size) {
            SFBuild94Fail(error, 4,
                @"LibRaw 返回位深/通道/字节数与实际请求不一致，拒绝静默量化");
            break;
        }
        NSData *bytes = [NSData dataWithBytes:image->data
                                       length:(NSUInteger)image->data_size];
        if (!bytes || bytes.length != image->data_size) {
            SFBuild94Fail(error, 5, @"LibRaw RGB 数据复制失败，可能内存不足");
            break;
        }
        result = [[SFBuild94RawResult alloc] initWithPixels:bytes
                                          bitsPerComponent:bits
                                                     width:image->width
                                                    height:image->height
                                                   decoder:[NSString stringWithUTF8String:libraw_version()]];
    } while (false);
    if (image) libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return result;
}
@end
