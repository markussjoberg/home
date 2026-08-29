import AVFoundation

/// Lukee ääniraidan PCM-datana ja tiivistää sen huippuarvoiksi
/// aaltomuodon piirtoa varten.
enum WaveformLoader {

    static func samples(from asset: AVAsset, bucketCount: Int) async throws -> [Float] {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }

        return try await Task.detached(priority: .utility) {
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else {
                throw reader.error ?? CocoaError(.fileReadUnknown)
            }

            // Huippuarvo per ~4096 näytteen jakso, uudelleenjako bucketeiksi lopuksi.
            let chunkSize = 4096
            var peaks: [Float] = []
            var currentPeak: Int32 = 0
            var filled = 0

            while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
                guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
                let totalLength = CMBlockBufferGetDataLength(blockBuffer)
                let evenLength = totalLength - (totalLength % 2)
                guard evenLength > 0 else { continue }

                var data = [Int16](repeating: 0, count: evenLength / 2)
                let status = data.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: evenLength, destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }

                for sample in data {
                    currentPeak = max(currentPeak, abs(Int32(sample)))
                    filled += 1
                    if filled == chunkSize {
                        peaks.append(Float(currentPeak) / Float(Int16.max))
                        currentPeak = 0
                        filled = 0
                    }
                }
            }
            if filled > 0 {
                peaks.append(Float(currentPeak) / Float(Int16.max))
            }
            guard !peaks.isEmpty else { return [] }

            var buckets = [Float](repeating: 0, count: bucketCount)
            for (index, peak) in peaks.enumerated() {
                let bucket = min(bucketCount - 1, index * bucketCount / peaks.count)
                buckets[bucket] = max(buckets[bucket], peak)
            }
            let maxPeak = buckets.max() ?? 0
            return maxPeak > 0 ? buckets.map { $0 / maxPeak } : buckets
        }.value
    }
}
