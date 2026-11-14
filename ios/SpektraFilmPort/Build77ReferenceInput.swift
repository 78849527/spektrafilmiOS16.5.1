import Foundation

/// Source rng.default_rng(771), image = .15 + .55*rng.random((6,4,3)).
/// Explicit IEEE754 payloads allow a native iPhone to use the EXACT SAME
/// 6x4x3 source input as Python build77_source_contract.py emit-taps.
/// No PNG gamma, ImageIO, or separate RNG implementation is involved.
enum Build77ReferenceInput {
    static let width=4
    static let height=6
    static let originalSourceInputSHA256 =
        "3584df8f8f1f5e4be21682e17218c4d360902320891bb753935f867dbf020e25"
    static let bits:[UInt64] = [
        0x3fda4a1ff7630132,0x3fd91b2e245ecc4c,0x3fd4c5616c6fc32e,
        0x3fd2c3d542bb348e,0x3fd26c2ee7bd2ee7,0x3fcfa90a33404168,
        0x3fda29bcff248904,0x3fe661ab2013dfef,0x3fd1667c15c52beb,
        0x3fe195ec94b15fbb,0x3fda8dc7d5c041ea,0x3fc69fe289af88a6,
        0x3fcb39a2fe03e6ab,0x3fd1351cd4f10219,0x3fde4851626f50c0,
        0x3fd3805a4585a828,0x3fe5bea91e558826,0x3fe652c49c34c1a6,
        0x3fd5fb0960e83770,0x3fe3775bef6ba380,0x3fdbe2ef7c45455c,
        0x3fe64bdf3b31d1e4,0x3fd15767977b47e9,0x3fe023aab9276918,
        0x3fce9e161cc7db33,0x3fe339f426b28308,0x3fe328b8c5aa0227,
        0x3fc402af3fd11b04,0x3fcbb4f8dedd656c,0x3fe1a9cf525aa555,
        0x3fe2c14f8147c24e,0x3fc98610db5839be,0x3fe2eab86b9a9e64,
        0x3fe412536fb56f78,0x3fd7c4faff188360,0x3fd1be33a4d68ef2,
        0x3fd1f97929e8be5e,0x3fe04846a4ef8d16,0x3fd0064085dc7813,
        0x3fe388ef93b082dc,0x3fd104a5905ef91d,0x3fe5321c6fd12452,
        0x3fc7f9a0e8b547f4,0x3fdd67f2730e0f66,0x3fd6db2e21a72930,
        0x3fe2a926ccf68d82,0x3fd7209c72ca69ee,0x3fe14f940b83c357,
        0x3fe143636d23902b,0x3fe3fe51cf474da5,0x3fcc549341bb0d09,
        0x3fe0d9573eb522ce,0x3fdbf24c1a91d0e4,0x3fe61ff8d0b3fbf8,
        0x3fcc083556070478,0x3fcf76c46a7126c0,0x3fde6ad0cd2d0438,
        0x3fe3d88d2e5d7c94,0x3fd8230d5536218e,0x3fc76aabce3e7d80,
        0x3fdefdc312134f22,0x3fe2f838951fd6f4,0x3fe2699d2815f0a7,
        0x3fd1e55b3454d9ce,0x3fd05de48c8893b3,0x3fdd880533a70e48,
        0x3fdeb7c37fe300b8,0x3fdf3f3a5f8fe324,0x3fc55df24ca20821,
        0x3fdfd05bd2e47654,0x3fe326c91af13fc6,0x3fe0026409d9a7c8
    ]
    static var values:[Double] { bits.map(Double.init(bitPattern:)) }
}
