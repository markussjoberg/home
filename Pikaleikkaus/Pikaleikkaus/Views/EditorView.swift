import AVKit
import PhotosUI
import SwiftUI

/// Photos-valitsimesta tuotava video kopioidaan omaan tmp-hakemistoon,
/// koska valitsimen antama tiedosto on väliaikainen.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Import", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return MovieFile(url: copy)
        }
    }
}

struct EditorView: View {
    @State private var model = EditorModel()
    @State private var pickedVideos: [PhotosPickerItem] = []
    @State private var pickedAudioSource: PhotosPickerItem?
    @State private var showsMusicImporter = false
    @State private var trimTarget: Clip?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                previewArea
                formatControls
                TimelineStrip(model: model, trimTarget: $trimTarget)
                importAndExportBar
            }
            .padding(.horizontal)
            .navigationTitle("Pikaleikkaus")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: pickedVideos) { _, items in
            guard !items.isEmpty else { return }
            pickedVideos = []
            importVideos(items, audioOnly: false)
        }
        .onChange(of: pickedAudioSource) { _, item in
            guard let item else { return }
            pickedAudioSource = nil
            importVideos([item], audioOnly: true)
        }
        .onChange(of: model.format) { model.refreshPreview() }
        .onChange(of: model.crossfade) { model.refreshPreview() }
        .fileImporter(
            isPresented: $showsMusicImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            importMusicFile(result)
        }
        .sheet(item: $trimTarget) { clip in
            TrimSheet(clip: clip) { updated in
                model.update(updated)
            }
        }
        .sheet(item: $model.exportResult) { result in
            exportSheet(result)
        }
        .alert("Virhe", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .overlay {
            if model.isExporting {
                exportingOverlay
            }
        }
    }

    // MARK: - Osat

    private var previewArea: some View {
        Group {
            if model.videoClips.isEmpty {
                ContentUnavailableView(
                    "Ei klippejä",
                    systemImage: "film.stack",
                    description: Text("Lisää videoita alareunan painikkeesta.")
                )
            } else {
                VideoPlayer(player: model.player)
                    .aspectRatio(model.format.aspectRatio, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var formatControls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Kuvasuhde", selection: $model.format) {
                    ForEach(OutputFormat.allCases) { format in
                        Text(format.label).tag(format)
                    }
                }
                .pickerStyle(.segmented)

                Toggle("Crossfade", isOn: $model.crossfade)
                    .toggleStyle(.button)
            }
            if model.crossfade {
                HStack {
                    Text("Häivytys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $model.crossfadeDuration, in: 0.2...1.5) { editing in
                        if !editing {
                            model.refreshPreview()
                        }
                    }
                    Text(String(format: "%.1f s", model.crossfadeDuration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var importAndExportBar: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickedVideos, matching: .videos) {
                Label("Klipit", systemImage: "plus.rectangle.on.rectangle")
            }
            .buttonStyle(.bordered)

            Menu {
                PhotosPicker(selection: $pickedAudioSource, matching: .videos) {
                    Label("Ääni videosta", systemImage: "waveform.badge.plus")
                }
                Button {
                    showsMusicImporter = true
                } label: {
                    Label("Musiikki tiedostosta", systemImage: "music.note")
                }
            } label: {
                Label("Ääni", systemImage: "waveform")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                Task { await model.export() }
            } label: {
                Label("Vie", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.videoClips.isEmpty || model.isExporting)
        }
        .padding(.bottom, 8)
    }

    private func exportSheet(_ result: ExportResult) -> some View {
        VStack(spacing: 16) {
            Text("Video on valmis")
                .font(.headline)
            Text("Jaa Viesteihin tai someen, tai valitse ”Tallenna video” lisätäksesi sen Kuviin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ShareLink(item: result.url) {
                Label("Jaa tai tallenna", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .presentationDetents([.fraction(0.3)])
    }

    private var exportingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
            ProgressView("Viedään…")
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    // MARK: - Tuonti

    private func importVideos(_ items: [PhotosPickerItem], audioOnly: Bool) {
        Task {
            for item in items {
                do {
                    guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                        model.errorMessage = "Klipin tuonti epäonnistui."
                        continue
                    }
                    await model.addClip(url: movie.url, audioOnly: audioOnly)
                } catch {
                    model.errorMessage = "Klipin tuonti epäonnistui: \(error.localizedDescription)"
                }
            }
        }
    }

    private func importMusicFile(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            model.errorMessage = "Tiedoston avaus epäonnistui: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer {
                    if accessing {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("Import", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let copy = directory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension)
                try FileManager.default.copyItem(at: url, to: copy)
                Task { await model.addClip(url: copy, audioOnly: true) }
            } catch {
                model.errorMessage = "Tiedoston kopiointi epäonnistui: \(error.localizedDescription)"
            }
        }
    }
}

#Preview {
    EditorView()
}
