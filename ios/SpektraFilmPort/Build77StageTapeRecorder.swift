import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Build77-only diagnostics. Does not alter source pixel arithmetic or switch
/// rendering modes. Existing production stageDoubleObserver callbacks pass
/// copied Double samples here only when the caller explicitly requests a tape.
/// IMPORTANT: stage names are the actual iOS callback names, NOT claimed
/// equivalent to the Python canonical seven taps until separately proven.
final class Build77StageTapeRecorder {
    enum TapeError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    private struct Sample {
        let name: String
        let values: [Double]
        let shape: [Int]
        let shapeMeaning: String
    }

    private let width: Int
    private let height: Int
    private let maxTotalElements: Int
    private var totalElements = 0
    private var samples: [Sample] = []
    private var errorMessage: String?

    init(width: Int, height: Int, maxTotalElements: Int = 2_000_000) throws {
        guard width > 0, height > 0, width <= 100_000,
              height <= 100_000, maxTotalElements > 0 else {
            throw TapeError.invalid("Build77 诊断：输入尺寸或显式内存上限无效")
        }
        self.width = width
        self.height = height
        self.maxTotalElements = maxTotalElements
    }

    func observe(_ stage: String, _ values: [Double]) {
        if errorMessage != nil { return }
        guard !stage.isEmpty,
              stage.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) ||
                  ($0 >= 65 && $0 <= 90) ||
                  ($0 >= 97 && $0 <= 122) ||
                  $0 == 45 || $0 == 95
              }) else {
            errorMessage = "Build77 诊断：不安全的阶段文件名"
            return
        }
        guard !samples.contains(where: { $0.name == stage }) else {
            errorMessage = "Build77 诊断：重复阶段 \(stage)，拒绝覆盖"
            return
        }
        guard values.count <= maxTotalElements - totalElements else {
            errorMessage = "Build77 诊断：Float64 阶段缓存超过用户指定内存上限"
            return
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        let (rgbCount, rgbOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
        guard !overflow && !rgbOverflow else {
            errorMessage = "Build77 诊断：图像尺寸溢出"
            return
        }
        let looksLikeRGB = values.count == rgbCount
        let shape = looksLikeRGB ? [height, width, 3] : [values.count]
        // Equal storage length does not prove that this stage contains RGB.
        let meaning = looksLikeRGB ? "HxWx3_storage_only" : "unmapped_flat_vector"
        samples.append(Sample(
            name: stage, values: values, shape: shape,
            shapeMeaning: meaning
        ))
        totalElements += values.count
    }

    /// Source topology invariant for diagnostic captures of the REAL
    /// OriginalSourcePhysicalImage pipeline. This verifies that required
    /// observed source-stage arrays exist, are ordered and retain dimensions.
    /// It intentionally does NOT assert Python numerical equivalence.
    func requirePhysicalSourceTopology(positiveFilm: Bool) throws {
        if let errorMessage { throw TapeError.invalid(errorMessage) }
        let names=samples.map { $0.name }
        let keys=positiveFilm
            ? ["iosInput","rgbPre","logRaw","density","printed","iosOutput"]
            : ["iosInput","rgbPre","logRaw","density","paperLogExposure",
               "paperDevelopedDensity","printed","iosOutput"]
        let pixelCount=width*height*3
        var previousIndex = -1
        for key in keys {
            guard let index=names.firstIndex(of:key),index>previousIndex,
                  samples[index].values.count==pixelCount else {
                throw TapeError.invalid(
                    "Build77 源阶段缺失、顺序错误或 Double 尺寸错误：" + key
                )
            }
            previousIndex=index
        }
        if positiveFilm &&
            (names.contains("paperLogExposure") ||
             names.contains("paperDevelopedDensity")) {
            throw TapeError.invalid(
                "Build77 正片直扫不包含相纸曝光／相纸密度，禁止伪造 tap"
            )
        }
    }

    private static func npy(_ sample: Sample) throws -> Data {
        let dimensions = sample.shape.map(String.init).joined(separator: ", ")
        let tuple = sample.shape.count == 1 ? "(\(dimensions),)" : "(\(dimensions))"
        let prefix = "{'descr': '<f8', 'fortran_order': False, 'shape': \(tuple), }"
        let headerBytes = Array(prefix.utf8)
        // NumPy 1.0 file header: 6 magic, 2 version, 2 header length,
        // 16-byte alignment; exactly one ASCII newline at the end.
        let padding = (16 - ((10 + headerBytes.count + 1) % 16)) % 16
        let header = headerBytes + Array(repeating: UInt8(32), count: padding) + [10]
        guard header.count <= Int(UInt16.max) else {
            throw TapeError.invalid("Build77 诊断：NPY v1 header 过长")
        }
        let length = UInt16(header.count)
        var output = Data([0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59, 0x01, 0x00,
                           UInt8(length & 0xff), UInt8(length >> 8)])
        output.append(contentsOf: header)
        // Do not convert via Float32, clamp, normalize, replace NaN or reorder.
        for value in sample.values {
            var word = value.bitPattern.littleEndian
            withUnsafeBytes(of: &word) { output.append(contentsOf: $0) }
        }
        return output
    }

    func write(to folder: URL) throws {
        if let errorMessage {
            throw TapeError.invalid(errorMessage)
        }
        guard !samples.isEmpty else {
            throw TapeError.invalid("Build77 诊断：没有捕捉到任何阶段")
        }
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: nil
        )
        var records: [[String: Any]] = []
        for sample in samples {
            let data = try Self.npy(sample)
            try data.write(to: folder.appendingPathComponent(sample.name + ".npy"),
                           options: .atomic)
            let nonfinite = sample.values.filter { !$0.isFinite }.count
            var record: [String: Any] = [
                "name": sample.name,
                "shape": sample.shape,
                "shape_meaning": sample.shapeMeaning,
                "dtype": "<f8",
                "count": sample.values.count,
                "nonfinite_count": nonfinite,
                "bytes": data.count
            ]
            #if canImport(CryptoKit)
            record["file_sha256"] = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            #endif
            records.append(record)
        }
        let manifest: [String: Any] = [
            "status": "IOS_INTERNAL_DIAGNOSTIC_NOT_PYTHON_TAP_PARITY",
            "width": width, "height": height,
            "max_total_double_elements": maxTotalElements,
            "observations": records,
            "message": "Callback labels are original iOS stage names. No equivalence or numerical tolerance is inferred."
        ]
        let json = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try json.write(to: folder.appendingPathComponent("manifest.json"),
                       options: .atomic)
    }
}

#if os(iOS)
extension Build77StageTapeRecorder {
    /// Explicit device diagnostic entrypoint using the *actual* full-Double
    /// production image path. Never runs automatically during normal preview
    /// or export and does not change user's original resolution.
    static func capturePhysical(
        _ input: OriginalSourcePixelIO.Frame,
        parameters: OriginalSourcePhysicalImage.Parameters,
        into folder: URL,
        maxTotalElements: Int = 2_000_000
    ) throws -> OriginalSourcePixelIO.Frame {
        let recorder = try Build77StageTapeRecorder(
            width: input.width, height: input.height,
            maxTotalElements: maxTotalElements
        )
        recorder.observe("iosInput", input.rgb)
        let output = try OriginalSourcePhysicalImage.develop(
            input, parameters: parameters,
            stageDoubleObserver: { name, values in recorder.observe(name, values) }
        )
        recorder.observe("iosOutput", output.rgb)
        try recorder.requirePhysicalSourceTopology(
            positiveFilm:SpectralPhysics.isPositiveFilm(parameters.filmID)
        )
        try recorder.write(to: folder)
        return output
    }
}
#endif
