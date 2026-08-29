import AVFoundation
import CoreGraphics

enum OutputFormat: String, CaseIterable, Identifiable {
    case portrait
    case landscape

    var id: String { rawValue }

    var renderSize: CGSize {
        switch self {
        case .portrait: CGSize(width: 1080, height: 1920)
        case .landscape: CGSize(width: 1920, height: 1080)
        }
    }

    var label: String {
        switch self {
        case .portrait: "Pysty 9:16"
        case .landscape: "Vaaka 16:9"
        }
    }

    var aspectRatio: CGFloat {
        renderSize.width / renderSize.height
    }
}

struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let duration: CMTime
}

/// Rakentaa AVMutableCompositionin aikajanan klipeistä:
/// - videoklipit peräkkäin kahdelle raidalle vuorotellen (A/B), jotta
///   crossfade voidaan tehdä opacity-rampilla päällekkäisyyskohdassa
/// - klippien omat äänet samalla A/B-jaolla omille ääniraidoilleen
///   (crossfaden aikana molemmat soivat, mikä toimii äänen ristihäivytyksenä)
/// - pelkkä ääni -klipit omille raidoilleen ajasta 0 alkaen
enum CompositionBuilder {

    static func build(
        clips: [Clip],
        format: OutputFormat,
        crossfade: Bool,
        crossfadeDuration: Double
    ) async throws -> BuiltComposition? {
        let videoClips = clips.filter { !$0.audioOnly && $0.hasVideo }
        let audioOnlyClips = clips.filter { $0.audioOnly && $0.hasAudio }
        guard !videoClips.isEmpty else { return nil }

        let composition = AVMutableComposition()
        let renderSize = format.renderSize

        guard
            let videoTrackA = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let videoTrackB = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrackA = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid),
            let audioTrackB = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }

        let audioParamsA = AVMutableAudioMixInputParameters(track: audioTrackA)
        let audioParamsB = AVMutableAudioMixInputParameters(track: audioTrackB)
        var audioParams: [AVMutableAudioMixInputParameters] = [audioParamsA, audioParamsB]

        // Häivytys ei saa olla pidempi kuin puolet lyhyimmästä klipistä.
        var fadeSeconds = crossfade ? crossfadeDuration : 0
        if fadeSeconds > 0 {
            let shortest = videoClips.map { $0.trimmedDuration.seconds }.min() ?? 0
            fadeSeconds = max(0, min(fadeSeconds, shortest / 2))
        }
        let fade = CMTime(seconds: fadeSeconds, preferredTimescale: 600)

        struct PlacedClip {
            let track: AVMutableCompositionTrack
            let start: CMTime
            let end: CMTime
            let transform: CGAffineTransform
        }
        var placed: [PlacedClip] = []
        var cursor = CMTime.zero

        for (index, clip) in videoClips.enumerated() {
            let useTrackA = index.isMultiple(of: 2)
            let videoTrack = useTrackA ? videoTrackA : videoTrackB

            guard let sourceVideo = try await clip.asset.loadTracks(withMediaType: .video).first else { continue }
            try videoTrack.insertTimeRange(clip.trimmedRange, of: sourceVideo, at: cursor)

            let naturalSize = try await sourceVideo.load(.naturalSize)
            let preferredTransform = try await sourceVideo.load(.preferredTransform)
            let transform = fitTransform(
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                quarterTurns: clip.quarterTurns,
                renderSize: renderSize
            )

            let end = cursor + clip.trimmedDuration
            placed.append(PlacedClip(track: videoTrack, start: cursor, end: end, transform: transform))

            if !clip.isMuted, clip.hasAudio,
               let sourceAudio = try await clip.asset.loadTracks(withMediaType: .audio).first {
                let audioTrack = useTrackA ? audioTrackA : audioTrackB
                try audioTrack.insertTimeRange(clip.trimmedRange, of: sourceAudio, at: cursor)
                (useTrackA ? audioParamsA : audioParamsB).setVolume(clip.volume, at: cursor)
            }

            let isLast = index == videoClips.count - 1
            cursor = isLast ? end : end - fade
        }

        guard let lastEnd = placed.last?.end else { return nil }
        let totalDuration = lastEnd

        // Instruktiot: jokaiselle klipille "yksin näkyvissä" -jakso ja
        // klippien väliin päällekkäisyysjakso, jossa lähtevä klippi häivytetään.
        var instructions: [AVMutableVideoCompositionInstruction] = []
        for (index, item) in placed.enumerated() {
            let isFirst = index == 0
            let isLast = index == placed.count - 1
            let soloStart = isFirst ? item.start : item.start + fade
            let soloEnd = isLast ? item.end : item.end - fade

            if soloEnd > soloStart {
                let solo = AVMutableVideoCompositionInstruction()
                solo.timeRange = CMTimeRange(start: soloStart, end: soloEnd)
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                layer.setTransform(item.transform, at: soloStart)
                solo.layerInstructions = [layer]
                instructions.append(solo)
            }

            if !isLast, fade > .zero {
                let next = placed[index + 1]
                let overlapRange = CMTimeRange(start: soloEnd, end: item.end)
                let overlap = AVMutableVideoCompositionInstruction()
                overlap.timeRange = overlapRange

                let outgoing = AVMutableVideoCompositionLayerInstruction(assetTrack: item.track)
                outgoing.setTransform(item.transform, at: overlapRange.start)
                outgoing.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: overlapRange)

                let incoming = AVMutableVideoCompositionLayerInstruction(assetTrack: next.track)
                incoming.setTransform(next.transform, at: overlapRange.start)

                overlap.layerInstructions = [outgoing, incoming]
                instructions.append(overlap)
            }
        }

        // Taustaraidat (puhe, musiikki, toisen klipin ääni) alkavat ajasta 0
        // ja katkeavat viimeistään videon loppuun.
        for clip in audioOnlyClips where !clip.isMuted {
            guard let sourceAudio = try await clip.asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }

            var range = clip.trimmedRange
            if range.duration > totalDuration {
                range = CMTimeRange(start: range.start, duration: totalDuration)
            }
            try track.insertTimeRange(range, of: sourceAudio, at: .zero)

            let params = AVMutableAudioMixInputParameters(track: track)
            params.setVolume(clip.volume, at: .zero)
            audioParams.append(params)
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioParams

        return BuiltComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: audioMix,
            duration: totalDuration
        )
    }

    /// Kuvan sovitus renderSizeen: preferredTransform (kameran orientaatio) +
    /// käyttäjän kierto, sitten aspect fit -skaalaus ja keskitys.
    private static func fitTransform(
        naturalSize: CGSize,
        preferredTransform: CGAffineTransform,
        quarterTurns: Int,
        renderSize: CGSize
    ) -> CGAffineTransform {
        var base = preferredTransform
        let turns = ((quarterTurns % 4) + 4) % 4
        if turns > 0 {
            base = base.concatenating(CGAffineTransform(rotationAngle: CGFloat(turns) * .pi / 2))
        }

        let transformedRect = CGRect(origin: .zero, size: naturalSize).applying(base)
        let fittedSize = CGSize(width: abs(transformedRect.width), height: abs(transformedRect.height))
        guard fittedSize.width > 0, fittedSize.height > 0 else { return base }

        let scale = min(renderSize.width / fittedSize.width, renderSize.height / fittedSize.height)
        let tx = -transformedRect.minX * scale + (renderSize.width - fittedSize.width * scale) / 2
        let ty = -transformedRect.minY * scale + (renderSize.height - fittedSize.height * scale) / 2

        return base
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }
}
