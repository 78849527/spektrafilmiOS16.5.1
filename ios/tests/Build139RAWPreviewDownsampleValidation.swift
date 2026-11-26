import Foundation

/// Standalone executable: compile with Build139RAWPreviewDownsample.swift
/// and verify RAW linear area downsampling. Not a whole-RAW visual certificate.
@main
struct Build139RAWPreviewDownsampleValidation {
    static func require(_ condition:Bool,_ note:String) {
        precondition(condition,"Build139 RAW preview: "+note)
    }

    static func sample(_ value:UInt16)->Double {
        Double(Float(value)/Float(65535.0))
    }

    static func rawBytes(width:Int,height:Int)->Data {
        var bytes=Data(count:width*height*6)
        bytes.withUnsafeMutableBytes { (raw:UnsafeMutableRawBufferPointer) in
            let ptr=raw.bindMemory(to:UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let values:[UInt16] = [
                        x.isMultiple(of:2) ? 10_000 : 40_000,
                        y.isMultiple(of:2) ? 5_000 : 60_000,
                        32_768
                    ]
                    for ch in 0..<3 {
                        let k=(y*width+x)*6+2*ch
                        ptr[k]=UInt8(truncatingIfNeeded:values[ch])
                        ptr[k+1]=UInt8(truncatingIfNeeded:values[ch]>>8)
                    }
                }
            }
        }
        return bytes
    }

    static func main() throws {
        let original=rawBytes(width:512,height:384)
        let sourceHash=original.prefix(48)
        let preview=try Build139RAWPreviewDownsample.frame(
            packedRGB16:original,width:512,height:384,maxLongEdge:256
        )
        require(preview.width==256 && preview.height==192,"source geometry")
        require(preview.rgb.count==256*192*3,"output channel count")
        let wantedR=(sample(10_000)+sample(40_000))/2.0
        let wantedG=(sample(5_000)+sample(60_000))/2.0
        let wantedB=sample(32_768)
        for i in stride(from:0,to:preview.rgb.count,by:3) {
            require(abs(preview.rgb[i]-wantedR)<1e-12,"linear red area average")
            require(abs(preview.rgb[i+1]-wantedG)<1e-12,"linear green area average")
            require(abs(preview.rgb[i+2]-wantedB)<1e-12,"unclipped blue")
        }
        require(original.prefix(48)==sourceHash,"source bytes not modified")

        let exact=rawBytes(width:3,height:2)
        let identity=try Build139RAWPreviewDownsample.frame(
            packedRGB16:exact,width:3,height:2,maxLongEdge:256
        )
        require(identity.width==3 && identity.height==2,"small image identity")
        require(identity.rgb[0].bitPattern==sample(10_000).bitPattern,
                "source UInt16 -> Float32 -> Double identity")
        require(identity.rgb[3].bitPattern==sample(40_000).bitPattern,
                "exact Float32 quantization")
        do {
            _=try Build139RAWPreviewDownsample.frame(
                packedRGB16:Data(exact.dropLast()),width:3,height:2
            )
            preconditionFailure("truncated RAW should refuse")
        } catch Build139RAWPreviewDownsample.Failure.invalid {
            // Must reject instead of decoding an embedded JPEG fallback.
        }
        // OPT-01 exact cache identity, copy-on-write and invalidation.
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:url) }
        try original.write(to:url)
        let key=Build139RAWPreviewDownsample.CacheKey.make(
            url:url,crop:[],maxLongEdge:256
        )!
        let cache=Build139RAWPreviewDownsample.InputCache()
        require(cache.lookup(key)==nil,"cold cache")
        cache.store(.init(key:key,reduced:preview,sourceWidth:512,sourceHeight:384))
        let hit=cache.lookup(key)!
        require(hit.sourceWidth==512 && hit.sourceHeight==384,"cached original geometry")
        require(hit.reduced.rgb.map { $0.bitPattern } == preview.rgb.map { $0.bitPattern },
                "cached input is bitwise identical")
        var copy=hit.reduced.rgb
        copy[0] += 1
        require(cache.lookup(key)!.reduced.rgb[0].bitPattern==preview.rgb[0].bitPattern,
                "render mutation cannot change cached input")
        let cropped=Build139RAWPreviewDownsample.CacheKey.make(url:url,crop:[512,384,0,0,256,256],maxLongEdge:256)!
        let resized=Build139RAWPreviewDownsample.CacheKey.make(url:url,crop:[],maxLongEdge:512)!
        require(cache.lookup(cropped)==nil && cache.lookup(resized)==nil,"geometry key invalidation")
        try Data([0]).write(to:url)
        let changed=Build139RAWPreviewDownsample.CacheKey.make(url:url,crop:[],maxLongEdge:256)!
        require(cache.lookup(changed)==nil,"file change invalidates key")
        cache.clear()
        require(cache.lookup(key)==nil,"explicit eviction")
        print("PASS OPT-01 immutable preview input cache, geometry/file identity and eviction")
        print("PASS Build139 RAW linear ACES16 area input: 512x384 -> 256x192, " +
              "Float32 quantization, bounded RGB, no source mutation or fallback")
        print("NOT CERTIFIED: low-resolution spatial optics/grain do not equal " +
              "full-resolution Float64 results; test on physical iPhone 16.5.1")
    }
}
