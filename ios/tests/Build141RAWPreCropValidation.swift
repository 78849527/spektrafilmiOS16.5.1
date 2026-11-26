import Foundation

@main
struct Build141RAWPreCropValidation {
    static func require(_ ok:Bool,_ note:String) {
        precondition(ok,"Build141 source pixel crop: "+note)
    }
    static func packed(width:Int,height:Int)->Data {
        var bytes=Data(count:width*height*6)
        bytes.withUnsafeMutableBytes { (buffer:UnsafeMutableRawBufferPointer) in
            let ptr=buffer.bindMemory(to:UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    for ch in 0..<3 {
                        let sample=UInt16((y*width+x+ch*1200)%65536)
                        let pos=(y*width+x)*6+ch*2
                        ptr[pos]=UInt8(truncatingIfNeeded:sample)
                        ptr[pos+1]=UInt8(truncatingIfNeeded:sample>>8)
                    }
                }
            }
        }
        return bytes
    }
    static func pixel(_ data:Data,width:Int,x:Int,y:Int,ch:Int)->UInt16 {
        let i=(y*width+x)*6+ch*2
        return UInt16(data[i]) | (UInt16(data[i+1])<<8)
    }
    static func main() throws {
        let source=packed(width:512,height:384)
        let baseline=source
        let chosen=try Build141RAWPreCrop.selection(
            sourceWidth:512,sourceHeight:384,
            normalizedX:0.25,normalizedY:0.125,
            normalizedWidth:0.5,normalizedHeight:0.625
        )
        try chosen.validate()
        require(chosen.width>=64 && chosen.height>=64,"pixel geometry")
        let original=try Build81OriginalCrop.region(
            imageWidth:512,imageHeight:384,
            centerX:0.5,centerY:0.4375,
            sizeX:0.5,sizeY:0.625*384.0/512.0
        )
        require(original.x==chosen.x && original.y==chosen.y &&
                original.width==chosen.width &&
                original.height==chosen.height,
                "Build81 crop nearest-even source coordinates")
        let sliced=try Build141RAWPreCrop.cropPackedRGB16(
            source,sourceWidth:512,sourceHeight:384,selection:chosen
        )
        require(sliced.count==chosen.width*chosen.height*6,
                "reduced ACES16 alloc only")
        for y in [0,chosen.height/2,chosen.height-1] {
            for x in [0,chosen.width/2,chosen.width-1] {
                for ch in 0..<3 {
                    require(pixel(sliced,width:chosen.width,x:x,y:y,ch:ch) ==
                        pixel(source,width:512,x:chosen.x+x,
                              y:chosen.y+y,ch:ch),
                            "bit-identical original UInt16 pixels")
                }
            }
        }
        require(source==baseline,"original RAW bytes untouched")
        let full=try Build141RAWPreCrop.selection(
            sourceWidth:512,sourceHeight:384,
            normalizedX:0,normalizedY:0,
            normalizedWidth:1,normalizedHeight:1
        )
        require(full.isWholeSource,"identity crop")
        let identity=try Build141RAWPreCrop.cropPackedRGB16(
            source,sourceWidth:512,sourceHeight:384,selection:full
        )
        require(identity==source,"full crop identity bits")
        do {
            _=try Build141RAWPreCrop.cropPackedRGB16(
                source,sourceWidth:384,sourceHeight:512,selection:chosen
            )
            preconditionFailure("mismatched rotated RAW accepted")
        } catch Build141RAWPreCrop.Failure.invalid {}
        do {
            _=try Build141RAWPreCrop.selection(
                sourceWidth:512,sourceHeight:384,
                normalizedX:0.95,normalizedY:0.2,
                normalizedWidth:0.3,normalizedHeight:0.5
            )
            preconditionFailure("out-of-range rectangle accepted")
        } catch Build141RAWPreCrop.Failure.invalid {}
        do {
            _=try Build141RAWPreCrop.selection(
                sourceWidth:512,sourceHeight:384,
                normalizedX:0.5,normalizedY:0.5,
                normalizedWidth:0.05,normalizedHeight:0.05
            )
            preconditionFailure("tiny unsupported 64px crop accepted")
        } catch Build141RAWPreCrop.Failure.invalid {}
        // Geometry-only: a 24MP decoded source may select a smaller
        // work rectangle without allocating a 24MP Double frame.
        let large=try Build141RAWPreCrop.selection(
            sourceWidth:6000,sourceHeight:4000,
            normalizedX:0.25,normalizedY:0.25,
            normalizedWidth:0.5,normalizedHeight:0.5
        )
        require(large.width==3000 && large.height==2000,"24MP source, 6MP crop geometry")
        print("PASS Build141: Build81 nearest-even crop geometry, packed UInt16 bit identity, original full-frame identity, orientation mismatch and small-area rejection")
        print("NOT CERTIFIED: 12MP real iPhone render, spatial edge equivalence with full-after-optics crop or measured Jetsam")
    }
}
