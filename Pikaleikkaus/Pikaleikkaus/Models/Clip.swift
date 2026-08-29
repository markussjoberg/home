import AVFoundation
import UIKit

/// Yksi aikajanan klippi. Sama tyyppi kattaa videoklipit ja pelkkänä äänenä
/// käytettävät lähteet (audioOnly) — ääniraita on kompositiossa joka
/// tapauksessa erillinen raita, joten ero on vain siinä, lisätäänkö
/// videoraita mukaan.
struct Clip: Identifiable {
    let id = UUID()
    let url: URL
    let asset: AVURLAsset
    let duration: CMTime
    let hasVideo: Bool
    let hasAudio: Bool
    let displayName: String

    var trimStart: CMTime
    var trimEnd: CMTime
    var isMuted = false
    var audioOnly: Bool
    var volume: Float = 1.0
    /// Käyttäjän lisäämä kierto neljänneskierroksina (0–3), preferredTransformin päälle.
    var quarterTurns = 0
    var thumbnail: UIImage?

    var trimmedRange: CMTimeRange {
        CMTimeRange(start: trimStart, end: trimEnd)
    }

    var trimmedDuration: CMTime {
        trimmedRange.duration
    }

    static func load(url: URL, audioOnly: Bool) async throws -> Clip {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        var clip = Clip(
            url: url,
            asset: asset,
            duration: duration,
            hasVideo: !videoTracks.isEmpty,
            hasAudio: !audioTracks.isEmpty,
            displayName: url.deletingPathExtension().lastPathComponent,
            trimStart: .zero,
            trimEnd: duration,
            audioOnly: audioOnly || videoTracks.isEmpty
        )

        if clip.hasVideo {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            if let cgImage = try? await generator.image(at: .zero).image {
                clip.thumbnail = UIImage(cgImage: cgImage)
            }
        }
        return clip
    }
}
