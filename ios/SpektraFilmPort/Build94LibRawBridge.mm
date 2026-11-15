#import "Build94LibRawBridge.h"
#include "libraw/libraw.h"

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
    return self;
}
@end

@implementation SFBuild94LibRaw
+ (SFBuild94RawResult *)decodeURL:(NSURL *)url error:(NSError **)error {
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
        // Fast compatibility path: full-res RGB8, camera WB, sRGB.
        // Unlike rawpy NumPy processing, this is LibRaw's own dcraw pipeline.
        libraw_set_output_bps(raw, 8);
        libraw_set_output_color(raw, 1);
        libraw_set_no_auto_bright(raw, 1);
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
        if (image->type != LIBRAW_IMAGE_BITMAP || image->bits != 8 ||
            image->colors != 3 || image->width == 0 || image->height == 0 ||
            (uint64_t)image->width * (uint64_t)image->height > 45000000 ||
            (uint64_t)image->width * image->height * 3 != image->data_size) {
            SFBuild94Fail(error, 4,
                @"LibRaw 返回的不是完整的 8-bit RGB 传感器显影图，禁止替代");
            break;
        }
        NSData *bytes = [NSData dataWithBytes:image->data
                                       length:(NSUInteger)image->data_size];
        if (!bytes || bytes.length != image->data_size) {
            SFBuild94Fail(error, 5, @"LibRaw RGB 数据复制失败，可能内存不足");
            break;
        }
        result = [[SFBuild94RawResult alloc] initWithRGB8:bytes
                                                    width:image->width
                                                   height:image->height
                                                  decoder:[NSString stringWithUTF8String:libraw_version()]];
    } while (false);
    if (image) libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return result;
}
@end
