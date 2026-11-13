import Foundation
import CryptoKit

/// All 28 original material profiles are verified as original little-endian
/// Float64 data BEFORE the iPhone build. This test also verifies the older
/// mobile Float32 byte values are precisely Float(originalDouble) for each
/// measured numeric entry: the fast mode was not silently changed.
enum SourceFloat64ProfileValidation {
    enum ValidationError: Error {
        case invalid(String)
    }

    private static func sha(_ value: Data) -> String {
        SHA256.hash(data:value).map {
            String(format:"%02x",$0)
        }.joined()
    }

    private static func data(
        _ text:String,count:Int,bytes:Int,label:String,
        allowEmpty:Bool=false
    ) throws -> Data? {
        if text.isEmpty && allowEmpty {return nil}
        guard let result=Data(base64Encoded:text),
              result.count == count*bytes else {
            throw ValidationError.invalid(
                "Invalid embedded source measured data " + label
            )
        }
        return result
    }

    private static func f64(_ data:Data,_ index:Int) -> Double {
        data.withUnsafeBytes { ptr in
            let bits=ptr.loadUnaligned(fromByteOffset:index*8,as:UInt64.self)
            return Double(bitPattern:UInt64(littleEndian:bits))
        }
    }
    private static func f32(_ data:Data,_ index:Int) -> Float {
        data.withUnsafeBytes { ptr in
            let bits=ptr.loadUnaligned(fromByteOffset:index*4,as:UInt32.self)
            return Float(bitPattern:UInt32(littleEndian:bits))
        }
    }

    private struct MeasuredField {
        let name:String
        let count:Int
        let mobile:String
        let source:String
        let optional:Bool
    }

    static func evaluate() throws {
        let rows=GeneratedSpectralData.profiles
        guard rows.count==28 else {
            throw ValidationError.invalid("28 original material profiles missing")
        }
        var preciseSamples=0
        var truncatedMobile=0
        var completeSublayers=0
        for (stock,record) in rows {
            let fields=[
                MeasuredField(
                    name:"logSensitivity",count:243,
                    mobile:record.logSensitivity,
                    source:record.sourceLogSensitivityF64,optional:false
                ),
                MeasuredField(
                    name:"channelDensity",count:243,
                    mobile:record.channelDensity,
                    source:record.sourceChannelDensityF64,optional:false
                ),
                MeasuredField(
                    name:"baseDensity",count:81,
                    mobile:record.baseDensity,
                    source:record.sourceBaseDensityF64,optional:false
                ),
                MeasuredField(
                    name:"logExposure",count:256,
                    mobile:record.logExposure,
                    source:record.sourceLogExposureF64,optional:false
                ),
                MeasuredField(
                    name:"densityCurves",count:768,
                    mobile:record.densityCurves,
                    source:record.sourceDensityCurvesF64,optional:false
                ),
                MeasuredField(
                    name:"densityCurvesLayers",count:2304,
                    mobile:record.densityCurvesLayers,
                    source:record.sourceDensityCurvesLayersF64,
                    optional:record.stage != "filming"
                )
            ]
            var originalBytes=Data()
            for field in fields {
                let exact=try data(
                    field.source,count:field.count,bytes:8,
                    label:stock+"/"+field.name,allowEmpty:field.optional
                )
                let packed=try data(
                    field.mobile,count:field.count,bytes:4,
                    label:stock+"/mobile/"+field.name,allowEmpty:field.optional
                )
                guard (exact == nil) == (packed == nil) else {
                    throw ValidationError.invalid(
                        "Mobile/source measured field presence differs " + stock
                    )
                }
                guard let exact,let packed else { continue }
                originalBytes.append(exact)
                for i in 0..<field.count {
                    let source=f64(exact,i)
                    let mobile=f32(packed,i)
                    guard source.isFinite && mobile.isFinite &&
                          Float(source).bitPattern==mobile.bitPattern else {
                        throw ValidationError.invalid(
                            "Original source float mismatch " +
                            "\(stock)/\(field.name)/\(i)"
                        )
                    }
                    if Double(mobile).bitPattern != source.bitPattern {
                        truncatedMobile+=1
                    }
                    preciseSamples+=1
                }
                if field.name=="densityCurvesLayers" &&
                   record.stage=="filming" {
                    completeSublayers+=1
                }
            }
            guard sha(originalBytes)==record.sourceFloat64SHA256,
                  record.sourceSHA256.count==64 else {
                throw ValidationError.invalid(
                    "Original source profile Float64 SHA mismatch: "+stock
                )
            }
            let masks=[
                (record.baseValidWavelengths,81),
                (record.sensitivityValidSamples,243),
                (record.scannerValidWavelengths,81)
            ]
            for (encoded,count) in masks {
                guard let mask=Data(base64Encoded:encoded),
                      mask.count==count,
                      mask.allSatisfy({ $0<=1 }) else {
                    throw ValidationError.invalid(
                        "Original source missing-wavelength mask "+stock
                    )
                }
            }
        }
        guard completeSublayers==20,
              truncatedMobile>0,preciseSamples>0 else {
            throw ValidationError.invalid(
                "Missing original 20-film sublayers or Float64 improvements"
            )
        }

        var dirSamples=0
        for (stock,dir) in GeneratedDIRData.records {
            guard let precise=try data(
                dir.sourceCorrectedCurvesF64,count:768,bytes:8,
                label:stock+"/source-DIR"
            ), let fast=try data(
                dir.correctedCurves,count:768,bytes:4,
                label:stock+"/mobile-DIR"
            ) else {
                throw ValidationError.invalid("Original DIR source absent")
            }
            guard sha(precise)==dir.sourceCorrectedSHA256 else {
                throw ValidationError.invalid(
                    "Original Float64 source DIR SHA mismatch "+stock
                )
            }
            for i in 0..<768 {
                let exact=f64(precise,i)
                guard exact.isFinite &&
                      Float(exact).bitPattern==f32(fast,i).bitPattern else {
                    throw ValidationError.invalid(
                        "Source DIR Float32 roundtrip mismatch "+stock
                    )
                }
            }
            dirSamples+=768
        }
        guard GeneratedDIRData.records.count==20 else {
            throw ValidationError.invalid("Original 20 film DIR profiles absent")
        }

        // Optical constants and 128 neutral film×print enlarger spectra
        // are also independent exact copies of the original source f64.
        let optics:[(String,String,Int)]=[
            (GeneratedOriginalOptics.mallettBasis,
             GeneratedOriginalOptics.sourceF64_mallettBasis,243),
            (GeneratedOriginalOptics.d55,
             GeneratedOriginalOptics.sourceF64_d55,81),
            (GeneratedOriginalOptics.d50,
             GeneratedOriginalOptics.sourceF64_d50,81),
            (GeneratedOriginalOptics.k75p,
             GeneratedOriginalOptics.sourceF64_k75p,81),
            (GeneratedOriginalOptics.cie1931,
             GeneratedOriginalOptics.sourceF64_cie1931,243),
            (GeneratedOriginalOptics.enlargerSource,
             GeneratedOriginalOptics.sourceF64_enlargerSource,81),
            (GeneratedOriginalOptics.enlargerNeutral,
             GeneratedOriginalOptics.sourceF64_enlargerNeutral,81),
            (GeneratedOriginalOptics.schottKG3,
             GeneratedOriginalOptics.sourceF64_schottKG3,81),
            (GeneratedOriginalOptics.dichroicCMYNeutral,
             GeneratedOriginalOptics.sourceF64_dichroicCMYNeutral,81)
        ]
        func opticalVerify(_ fast:String,_ original:String,_ count:Int)
            throws {
            guard let raw=try data(original,count:count,bytes:8,
                                   label:"source optics"),
                  let old=try data(fast,count:count,bytes:4,
                                   label:"mobile optics") else {
                throw ValidationError.invalid("Original optics data missing")
            }
            for i in 0..<count {
                let exact=f64(raw,i)
                guard exact.isFinite &&
                      Float(exact).bitPattern==f32(old,i).bitPattern else {
                    throw ValidationError.invalid(
                        "Optics original/mobile spectral mismatch"
                    )
                }
            }
        }
        for (fast,exact,count) in optics {
            try opticalVerify(fast,exact,count)
        }
        let pairs=GeneratedOriginalOptics.printIlluminantByPair
        let precisePairs=GeneratedOriginalOptics.sourceF64PrintIlluminantByPair
        guard pairs.count==128,
              Set(pairs.keys)==Set(precisePairs.keys) else {
            throw ValidationError.invalid(
                "128 source enlarger filter pairs incomplete"
            )
        }
        for (key,fast) in pairs {
            guard let exact=precisePairs[key] else {
                throw ValidationError.invalid("Pair lost "+key)
            }
            try opticalVerify(fast,exact,81)
        }
        print("PASS original Float64 source profiles: 28 materials, " +
              "\(preciseSamples) measured channels, " +
              "\(truncatedMobile) were rounded in legacy Float32; " +
              "20 exact DIR curves (\(dirSamples) nodes), " +
              "20 full nine-layer measurement sets, 9 optical spectra " +
              "and 128 real enlarger pair spectra. " +
              "Source SHA256, NaN masks and mobile Float32 remain intact.")
    }
}
