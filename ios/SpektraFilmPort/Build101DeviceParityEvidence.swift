import Foundation
import CryptoKit

/// Build101: real device opt-in evaluator for the EXISTING Build92 bundled
/// Python-vs-Swift physical-frame stage checks. Records the outcome on disk.
/// Never turns synthetic macOS tests or controlled source fixtures into
/// proof of full upstream default-mode parity.
enum Build101DeviceParityEvidence {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case let .invalid(message) = self { return message }
            return nil
        }
    }

    struct Report: Codable {
        let schema: Int
        let testedVersion: String
        let testedBuild: String
        let binarySourceCommit: String
        let binarySourceCommitVerified: Bool
        let deviceModel: String
        let osVersion: String
        let physicalDevice: Bool
        let exactIOS1651: Bool
        let referenceFixture: String
        let referenceManifestSHA256: String?
        let sourceScope: String
        let generatedUTC: String
        let durationSeconds: Double
        let status: String
        let evaluatorOutput: String?
        let firstFailure: String?
        let controlledParityPassOnTargetDevice: Bool
        let fullPythonOriginalCertified: Bool
        let limitations: [String]
    }

    static let fixture = "generated-physical-v1.8.22"
    static let limitations = [
        "Only Build92's bundled controlled 4-case stage reference scope",
        "Not a full screen/image or default parameter accuracy certificate",
        "Unseeded multiworker Python Numba grain is not certified",
        "No real large-frame iPhone peak RAM/thermal proof",
        "No complete RAW/16-bit/ICC/metadata/colourspace source parity",
        "Device stage result is not Build77 3-branch default/parameter proof"
    ]

    static func capture(
        version: String, build: String, binarySourceCommit: String,
        deviceModel: String, osVersion: String,
        physicalDevice: Bool, now: Date,
        referenceManifest: URL?,
        evaluate: () throws -> String
    ) -> Report {
        let began=Date()
        let isTarget=physicalDevice && osVersion=="16.5.1"
        let commitValid=binarySourceCommit.count==40 &&
            binarySourceCommit.unicodeScalars.allSatisfy {
                ("0123456789abcdef".unicodeScalars).contains($0)
            }
        var referenceDigest: String?
        var text: String?
        var failure: String?
        var ranSuccessfully=false
        do {
            guard let referenceManifest else {
                throw Failure.invalid(
                    "Build92 Python 原版源参考清单缺失，禁止宣称已对照"
                )
            }
            let data=try Data(contentsOf:referenceManifest)
            guard !data.isEmpty else {
                throw Failure.invalid(
                    "Build92 Python 原版清单为空，禁止开展对照"
                )
            }
            referenceDigest=SHA256.hash(data:data).map {
                String(format:"%02x",$0)
            }.joined()
            text=try evaluate()
            guard !(text?.trimmingCharacters(in:.whitespacesAndNewlines)
                      .isEmpty ?? true) else {
                throw Failure.invalid("原版阶段数值诊断没有返回有效报告")
            }
            ranSuccessfully=true
        } catch {
            failure=error.localizedDescription
        }

        let status: String
        if !ranSuccessfully {
            status="controlled_stage_failed_or_reference_missing"
        } else if isTarget && commitValid {
            status="controlled_stage_pass_on_physical_ios1651"
        } else if isTarget {
            status="controlled_stage_pass_missing_binary_commit"
        } else {
            status="controlled_stage_pass_non_target_environment"
        }
        let formatter=ISO8601DateFormatter()
        formatter.formatOptions=[.withInternetDateTime]
        return Report(
            schema:1,testedVersion:version,testedBuild:build,
            binarySourceCommit:binarySourceCommit,
            binarySourceCommitVerified:commitValid,
            deviceModel:deviceModel,osVersion:osVersion,
            physicalDevice:physicalDevice,exactIOS1651:isTarget,
            referenceFixture:fixture,
            referenceManifestSHA256:referenceDigest,
            sourceScope:"original-source-nonlinear-hanatos-spatial-dir-paper-aces-8bit",
            generatedUTC:formatter.string(from:now),
            durationSeconds:max(0,Date().timeIntervalSince(began)),
            status:status,evaluatorOutput:text,firstFailure:failure,
            controlledParityPassOnTargetDevice:ranSuccessfully &&
                isTarget && commitValid,
            fullPythonOriginalCertified:false,
            limitations:limitations
        )
    }

    static func encode(_ report: Report) throws -> Data {
        let encoder=JSONEncoder()
        encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        return try encoder.encode(report)
    }

    /// Both pass and fail must leave a record. Documents is not subject to
    /// Build98's temporary-export cleanup and contains no user photo bytes.
    static func write(_ report: Report, documents: URL) throws -> URL {
        let folder=documents.appendingPathComponent(
            "SpektraFilm Verification",isDirectory:true
        )
        try FileManager.default.createDirectory(
            at:folder,withIntermediateDirectories:true
        )
        let file=folder.appendingPathComponent(
            "Build101-controlled-parity-" + UUID().uuidString
        ).appendingPathExtension("json")
        try encode(report).write(to:file,options:.atomic)
        return file
    }
}
