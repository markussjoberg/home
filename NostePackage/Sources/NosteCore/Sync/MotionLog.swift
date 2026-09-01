import Foundation

/// Kiihtyvyysraakadatan tiivis binääripakkaus: 8 tavua/näyte (Float32 aika +
/// Float32 kiihtyvyys) → 30 min @ 50 Hz ≈ 0,7 Mt. JSON veisi ~20-kertaisesti.
/// Tämä on kalibroinnin kulta-aines: sillä pumppu- ja foilitunnistuksen voi
/// ajaa uusiksi jälkikäteen paremmilla kynnysarvoilla.
public enum MotionLog {

    /// Tiedostotunniste: "NMO1".
    private static let magic: [UInt8] = [0x4E, 0x4D, 0x4F, 0x31]

    public static func pack(_ samples: [MotionSample]) -> Data {
        var data = Data(capacity: 8 + samples.count * 8)
        data.append(contentsOf: magic)
        var count = UInt32(samples.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for sample in samples {
            var t = Float32(sample.t).bitPattern.littleEndian
            var a = Float32(sample.verticalAcceleration).bitPattern.littleEndian
            withUnsafeBytes(of: &t) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func unpack(_ data: Data) -> [MotionSample]? {
        guard data.count >= 8, Array(data.prefix(4)) == magic else { return nil }
        let count = data.subdata(in: 4..<8).withUnsafeBytes { $0.load(as: UInt32.self).littleEndian }
        guard data.count >= 8 + Int(count) * 8 else { return nil }
        var samples: [MotionSample] = []
        samples.reserveCapacity(Int(count))
        let body = data.subdata(in: 8..<(8 + Int(count) * 8))
        body.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for i in 0..<Int(count) {
                let t = Float32(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: i * 8, as: UInt32.self)))
                let a = Float32(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: i * 8 + 4, as: UInt32.self)))
                samples.append(MotionSample(t: TimeInterval(t), verticalAcceleration: Double(a)))
            }
        }
        return samples
    }
}

/// Koko session raakadata yhtenä jaettavana tiedostona (kalibrointia varten):
/// yhteenveto + GPS-jälki + pakattu kiihtyvyysdata + pumppuhetket.
public struct RawSessionExport: Codable {
    public var summary: SessionSummary
    public var track: [TrackPoint]
    /// MotionLog.pack-muodossa (JSONissa base64).
    public var motionPacked: Data?
    public var strokeTimes: [TimeInterval]?

    public init(summary: SessionSummary, track: [TrackPoint], motionPacked: Data?, strokeTimes: [TimeInterval]?) {
        self.summary = summary
        self.track = track
        self.motionPacked = motionPacked
        self.strokeTimes = strokeTimes
    }
}
