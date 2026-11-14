import Foundation

/// Build80/10-12: host validation of actual Apple CIRAWFilter control
/// contract. No synthetic JPEG is allowed to prove sensor RAW decoding.
enum Build80AppleRAWDevelopmentValidation {
    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let explanation) = self { return explanation }
            return nil
        }
    }

    private static func requireReject(_ label: String,
                                      _ options: Build80AppleRAWDevelopment.Options)
        throws {
        do {
            try Build80AppleRAWDevelopment.validate(options)
        } catch {
            return
        }
        throw Failure.invalid("Build80 allowed invalid Apple RAW option: " + label)
    }

    static func evaluate() throws {
        let r = Build80AppleRAWDevelopment.self
        try r.validate(.asShot)
        try r.validate(.daylightDiagnostic)
        try r.validate(.tungstenDiagnostic)
        for input in [Float(2_000), Float(50_000)] {
            try r.validate(.init(
                whiteBalance: .appleTemperature(
                    kelvin: input, tintOffset: 0),
                exposureEV: 0, appleLensCorrection: true))
        }
        for input in [Float(-150), Float(150)] {
            try r.validate(.init(
                whiteBalance: .appleTemperature(
                    kelvin: 5500, tintOffset: input),
                exposureEV: 0, appleLensCorrection: false))
        }
        for bad in [Float.nan, Float.infinity, -Float.infinity, Float(-10.01), Float(10.01)] {
            try requireReject("EV", .init(
                whiteBalance: .asShot,
                exposureEV: bad,
                appleLensCorrection: false))
        }
        for bad in [Float.nan, Float.infinity, Float(1999), Float(50001)] {
            try requireReject("temperature", .init(
                whiteBalance: .appleTemperature(
                    kelvin: bad, tintOffset: 0),
                exposureEV: 0, appleLensCorrection: false))
        }
        for bad in [Float.nan, -Float.infinity, Float(-150.01), Float(150.01)] {
            try requireReject("Apple tint offset", .init(
                whiteBalance: .appleTemperature(
                    kelvin: 5500, tintOffset: bad),
                exposureEV: 0, appleLensCorrection: false))
        }

        // A non-RAW file must not enter the Apple RAW backend, even when
        // it has valid RGBA bytes or a misleading .dng suffix.
        let jpeg = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: jpeg)
        defer { try? FileManager.default.removeItem(at: jpeg) }
        do {
            _ = try r.probe(jpeg, options: .asShot)
            throw Failure.invalid("Apple RAW probe accepted ordinary JPEG")
        } catch Failure.invalid {
            throw Failure.invalid("Apple RAW probe accepted ordinary JPEG")
        } catch {
            // Expected container/signature failure, no JPEG fallback.
        }
        print("PASS Build80 Apple RAW diagnostic control bounds "
              + "and non-RAW fail-closed; 4x4 RAW sensor decode, "
              + "X-Trans, lensfun and rawpy parity require real files/device.")
    }
}
