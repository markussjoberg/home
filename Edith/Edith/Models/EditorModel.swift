import AVFoundation
import Observation
import SwiftUI

struct ExportResult: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
@Observable
final class EditorModel {
    var clips: [Clip] = []
    var format: OutputFormat = .portrait
    var crossfade = false
    var crossfadeDuration = 0.5

    let player = AVPlayer()
    var isExporting = false
    var exportResult: ExportResult?
    var errorMessage: String?

    private var previewTask: Task<Void, Never>?

    var videoClips: [Clip] { clips.filter { !$0.audioOnly } }
    var audioOnlyClips: [Clip] { clips.filter { $0.audioOnly } }

    /// Likiarvo lopullisesta kestosta aikajanan otsikkoon (builder voi
    /// lyhentää häivytystä, jos jokin klippi on sitä lyhyempi).
    var totalDurationSeconds: Double {
        let videos = videoClips
        guard !videos.isEmpty else { return 0 }
        let sum = videos.reduce(0) { $0 + $1.trimmedDuration.seconds }
        let fades = crossfade ? crossfadeDuration * Double(videos.count - 1) : 0
        return max(0, sum - fades)
    }

    func addClip(url: URL, audioOnly: Bool) async {
        do {
            let clip = try await Clip.load(url: url, audioOnly: audioOnly)
            clips.append(clip)
            refreshPreview()
        } catch {
            errorMessage = "Klipin tuonti epäonnistui: \(error.localizedDescription)"
        }
    }

    func update(_ clip: Clip, refresh: Bool = true) {
        guard let index = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        clips[index] = clip
        if refresh {
            refreshPreview()
        }
    }

    func remove(_ clip: Clip) {
        clips.removeAll { $0.id == clip.id }
        refreshPreview()
    }

    /// Siirtää klippiä oman kategoriansa (video / pelkkä ääni) sisällä.
    func move(_ clip: Clip, by offset: Int) {
        guard offset != 0, let from = clips.firstIndex(where: { $0.id == clip.id }) else { return }
        let step = offset > 0 ? 1 : -1
        var target = from + step
        while clips.indices.contains(target), clips[target].audioOnly != clip.audioOnly {
            target += step
        }
        guard clips.indices.contains(target) else { return }
        clips.swapAt(from, target)
        refreshPreview()
    }

    func refreshPreview() {
        previewTask?.cancel()
        let snapshot = clips
        let format = format
        let crossfade = crossfade
        let crossfadeDuration = crossfadeDuration

        previewTask = Task {
            do {
                guard let built = try await CompositionBuilder.build(
                    clips: snapshot,
                    format: format,
                    crossfade: crossfade,
                    crossfadeDuration: crossfadeDuration
                ) else {
                    player.replaceCurrentItem(with: nil)
                    return
                }
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                player.replaceCurrentItem(with: item)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Esikatselun rakentaminen epäonnistui: \(error.localizedDescription)"
            }
        }
    }

    /// Passthrough kelpaa, kun mitään ei tarvitse renderöidä uusiksi:
    /// yksi klippi ilman taustaääniä, kiertoa tai äänimuutoksia.
    private var passthroughCandidate: Clip? {
        guard videoClips.count == 1, audioOnlyClips.isEmpty else { return nil }
        let clip = videoClips[0]
        guard clip.quarterTurns % 4 == 0, !clip.isMuted, clip.volume == 1 else { return nil }
        return clip
    }

    func export() async {
        guard !isExporting else { return }
        isExporting = true
        defer { isExporting = false }

        if let clip = passthroughCandidate,
           let url = try? await Exporter.exportPassthrough(clip: clip) {
            exportResult = ExportResult(url: url)
            return
        }
        // Passthrough ei kelvannut tai epäonnistui (esim. kontti/koodekki) →
        // normaali kompositiopolku.
        do {
            guard let built = try await CompositionBuilder.build(
                clips: clips,
                format: format,
                crossfade: crossfade,
                crossfadeDuration: crossfadeDuration
            ) else {
                errorMessage = "Lisää ensin vähintään yksi videoklippi."
                return
            }
            let url = try await Exporter.export(built)
            exportResult = ExportResult(url: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
