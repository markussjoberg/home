import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Share-extensionin juuri: Kuvissa valitut videot → jaa → Edith.
/// Sama editori kuin appissa; vienti tallentaa Kuviin, koska share sheetiä
/// ei voi avata extensionin sisältä.
final class ShareViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let context = extensionContext
        let root = ShareEditorRoot(
            loadInitialURLs: { await Self.loadMovieURLs(from: context) },
            onFinish: { context?.completeRequest(returningItems: nil) }
        )

        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    static func loadMovieURLs(from context: NSExtensionContext?) async -> [URL] {
        guard let items = context?.inputItems as? [NSExtensionItem] else { return [] }
        var urls: [URL] = []
        for item in items {
            for provider in item.attachments ?? []
            where provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                if let url = try? await provider.copiedMovieURL() {
                    urls.append(url)
                }
            }
        }
        return urls
    }
}

private struct ShareEditorRoot: View {
    let loadInitialURLs: () async -> [URL]
    let onFinish: () -> Void

    @State private var model = EditorModel()
    @State private var loaded = false

    var body: some View {
        EditorView(model: model, context: .shareExtension(onFinish: onFinish))
            .task {
                guard !loaded else { return }
                loaded = true
                for url in await loadInitialURLs() {
                    await model.addClip(url: url, audioOnly: false)
                }
            }
    }
}

private extension NSItemProvider {
    /// loadFileRepresentation antaa tiedoston, joka on voimassa vain
    /// callbackin ajan — kopioidaan se heti omaan tmp-hakemistoon.
    func copiedMovieURL() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? CocoaError(.fileNoSuchFile))
                    return
                }
                do {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent("ShareImport", isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let fileExtension = url.pathExtension.isEmpty ? "mov" : url.pathExtension
                    let copy = directory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(fileExtension)
                    try FileManager.default.copyItem(at: url, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
