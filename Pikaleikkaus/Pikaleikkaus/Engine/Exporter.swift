import AVFoundation
import Foundation

enum ExportError: LocalizedError {
    case cannotCreateSession
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateSession: "Export-sessiota ei voitu luoda."
        case .failed(let reason): "Vienti epäonnistui: \(reason)"
        }
    }
}

enum Exporter {

    static func export(_ built: BuiltComposition) async throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pikaleikkaus-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

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
}
