import SwiftUI

/// Aikajana: videoklipit thumbnail-rivinä, taustaäänet omina riveinään alla.
struct TimelineStrip: View {
    var model: EditorModel
    @Binding var trimTarget: Clip?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.videoClips.isEmpty {
                HStack {
                    Text("Aikajana")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f s", model.totalDurationSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.videoClips) { clip in
                        videoCell(clip)
                    }
                }
            }
            .frame(height: model.videoClips.isEmpty ? 0 : 72)

            ForEach(model.audioOnlyClips) { clip in
                audioRow(clip)
            }
        }
    }

    // MARK: - Videoklippi

    private func videoCell(_ clip: Clip) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnail = clip.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }

            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)

            HStack(spacing: 4) {
                if clip.isMuted {
                    Image(systemName: "speaker.slash.fill")
                        .font(.system(size: 10))
                }
                Text(String(format: "%.1f s", clip.trimmedDuration.seconds))
                    .font(.system(size: 10).monospacedDigit())
            }
            .foregroundStyle(.white)
            .padding(4)
        }
        .frame(width: cellWidth(for: clip), height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            clipMenu(clip)
        }
    }

    private func cellWidth(for clip: Clip) -> CGFloat {
        let seconds = clip.trimmedDuration.seconds
        return CGFloat(max(64, min(200, seconds * 24)))
    }

    @ViewBuilder
    private func clipMenu(_ clip: Clip) -> some View {
        Button {
            trimTarget = clip
        } label: {
            Label("Trimmaa ja säädä", systemImage: "timeline.selection")
        }

        Button {
            var updated = clip
            updated.isMuted.toggle()
            model.update(updated)
        } label: {
            Label(clip.isMuted ? "Palauta ääni" : "Mykistä", systemImage: clip.isMuted ? "speaker.wave.2" : "speaker.slash")
        }

        Button {
            var updated = clip
            updated.quarterTurns += 1
            model.update(updated)
        } label: {
            Label("Käännä 90°", systemImage: "rotate.right")
        }

        if clip.hasAudio {
            Button {
                var updated = clip
                updated.audioOnly = true
                model.update(updated)
            } label: {
                Label("Käytä vain ääni", systemImage: "waveform")
            }
        }

        Divider()

        Button {
            model.move(clip, by: -1)
        } label: {
            Label("Siirrä vasemmalle", systemImage: "arrow.left")
        }

        Button {
            model.move(clip, by: 1)
        } label: {
            Label("Siirrä oikealle", systemImage: "arrow.right")
        }

        Divider()

        Button(role: .destructive) {
            model.remove(clip)
        } label: {
            Label("Poista", systemImage: "trash")
        }
    }

    // MARK: - Taustaääni

    private func audioRow(_ clip: Clip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(clip.isMuted ? .secondary : Color.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(clip.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Text(String(format: "%.1f s", clip.trimmedDuration.seconds))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: Binding(
                    get: { Double(clip.volume) },
                    set: { newValue in
                        var updated = clip
                        updated.volume = Float(newValue)
                        model.update(updated, refresh: false)
                    }
                ),
                in: 0...1
            ) { editing in
                if !editing {
                    model.refreshPreview()
                }
            }
            .frame(maxWidth: 140)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            audioMenu(clip)
        }
    }

    @ViewBuilder
    private func audioMenu(_ clip: Clip) -> some View {
        Button {
            trimTarget = clip
        } label: {
            Label("Trimmaa ja säädä", systemImage: "timeline.selection")
        }

        Button {
            var updated = clip
            updated.isMuted.toggle()
            model.update(updated)
        } label: {
            Label(clip.isMuted ? "Palauta ääni" : "Mykistä", systemImage: clip.isMuted ? "speaker.wave.2" : "speaker.slash")
        }

        if clip.hasVideo {
            Button {
                var updated = clip
                updated.audioOnly = false
                model.update(updated)
            } label: {
                Label("Käytä myös kuva", systemImage: "film")
            }
        }

        Divider()

        Button(role: .destructive) {
            model.remove(clip)
        } label: {
            Label("Poista", systemImage: "trash")
        }
    }
}
