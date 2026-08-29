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
                Text(audioSubtitle(clip))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if !clip.waveform.isEmpty {
                WaveformView(samples: clip.waveform, color: clip.isMuted ? .secondary : .accentColor)
                    .frame(width: 64, height: 24)
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

    private func audioSubtitle(_ clip: Clip) -> String {
        let duration = String(format: "%.1f s", clip.trimmedDuration.seconds)
        if clip.timelineOffsetSeconds > 0 {
            return duration + String(format: " · alkaa %.1f s", clip.timelineOffsetSeconds)
        }
        return duration
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

/// Kevyt aaltomuotopiirto Canvasilla — käytössä ääniriveillä ja
/// trimmausnäkymässä.
struct WaveformView: View {
    let samples: [Float]
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let barWidth = size.width / CGFloat(samples.count)
            for (index, sample) in samples.enumerated() {
                let height = max(1, CGFloat(sample) * size.height)
                let rect = CGRect(
                    x: CGFloat(index) * barWidth + barWidth * 0.15,
                    y: (size.height - height) / 2,
                    width: barWidth * 0.7,
                    height: height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth * 0.35),
                    with: .color(color)
                )
            }
        }
    }
}
