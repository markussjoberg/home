import AVFoundation
import Foundation
import Photos

enum ExportError: LocalizedError {
    case cannotCreateSession
    case failed(String)
    case photosDenied

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession: "Export-sessiota ei voitu luoda."
        case .failed(let reason): "Vienti epäonnistui: \(reason)"
        case .photosDenied: "Ei lupaa tallentaa Kuviin. Salli tallennus Asetuksista."
        }
    }
}

enum Exporter {

    static func export(_ built: BuiltComposition) async throws -> URL {
        let outputURL = temporaryURL(fileExtension: "mp4")
        guard let session = AVAssetExportSession(
            asset: built.composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.cannotCreateSession
        }

        session.videoComposition = built.videoComposition
        session.audioMix = built.audioMix
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true

        await session.export()

        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "tuntematon virhe"
            throw ExportError.failed(reason)
        }
        return outputURL
    }

    /// Aito trimmaus ilman uudelleenpakkausta: yksi klippi, ei muunnoksia.
    /// Lopputulos säilyttää alkuperäisen kuvanlaadun ja orientaation.
    static func exportPassthrough(clip: Clip) async throws -> URL {
        let outputURL = temporaryURL(fileExtension: "mov")
        guard let session = AVAssetExportSession(
            asset: clip.asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            throw ExportError.cannotCreateSession
        }

        session.timeRange = clip.trimmedRange
        session.outputURL = outputURL
        session.outputFileType = .mov

        await session.export()

        guard session.status == .completed else {
            let reason = session.error?.localizedDescription ?? "tuntematon virhe"
            throw ExportError.failed(reason)
        }
        return outputURL
    }

    private static func temporaryURL(fileExtension: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Edith-\(Int(Date().timeIntervalSince1970))")
            .appendingPathExtension(fileExtension)
        try? FileManager.default.removeItem(at: url)
        return url
    }
}

/// Tallennus Kuviin — käytössä myös share-extensionissa, jossa share sheetiä
/// ei voi avata.
enum PhotosSaver {

    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw ExportError.photosDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
