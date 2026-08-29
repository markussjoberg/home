import AVFoundation
import SwiftUI

/// Klipin trimmaus Kuvat-tyylisillä keltaisilla kahvoilla filminauhan
/// (tai äänellä aaltomuodon) päällä. Muutokset kirjoitetaan malliin vasta
/// ”Valmis”-painikkeesta, jotta esikatselua ei rakenneta joka vedolla.
struct TrimSheet: View {
    let clip: Clip
    /// Videoaikajanan kokonaiskesto — taustaraidan aloituskohdan yläraja.
    let timelineSeconds: Double
    let onSave: (Clip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startSeconds: Double
    @State private var endSeconds: Double
    @State private var volume: Double
    @State private var offsetSeconds: Double
    @State private var frames: [UIImage] = []

    private let durationSeconds: Double

    init(clip: Clip, timelineSeconds: Double, onSave: @escaping (Clip) -> Void) {
        self.clip = clip
        self.timelineSeconds = timelineSeconds
        self.onSave = onSave
        self.durationSeconds = max(0.1, clip.duration.seconds)
        _startSeconds = State(initialValue: clip.trimStart.seconds)
        _endSeconds = State(initialValue: clip.trimEnd.seconds)
        _volume = State(initialValue: Double(clip.volume))
        _offsetSeconds = State(initialValue: clip.timelineOffsetSeconds)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trimmaus") {
                    FilmstripTrimView(
                        duration: durationSeconds,
                        frames: frames,
                        waveform: clip.waveform,
                        start: $startSeconds,
                        end: $endSeconds
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                    HStack {
                        Text(timeLabel(startSeconds))
                        Spacer()
                        Text(timeLabel(endSeconds - startSeconds))
                            .fontWeight(.semibold)
                        Spacer()
                        Text(timeLabel(endSeconds))
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Section("Ääni") {
                    HStack {
                        Image(systemName: "speaker.wave.1")
                        Slider(value: $volume, in: 0...1)
                        Image(systemName: "speaker.wave.3")
                    }
                }

                if clip.audioOnly, timelineSeconds > 0 {
                    Section("Aloituskohta aikajanalla") {
                        Slider(value: $offsetSeconds, in: 0...timelineSeconds)
                        Text("Raita alkaa kohdasta \(timeLabel(offsetSeconds))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(clip.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kumoa") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Valmis") {
                        var updated = clip
                        updated.trimStart = CMTime(seconds: startSeconds, preferredTimescale: 600)
                        updated.trimEnd = CMTime(seconds: endSeconds, preferredTimescale: 600)
                        updated.volume = Float(volume)
                        updated.timelineOffsetSeconds = offsetSeconds
                        onSave(updated)
                        dismiss()
                    }
                }
            }
            .task {
                await loadFrames()
            }
        }
        .presentationDetents([.medium])
    }

    private func loadFrames() async {
        guard clip.hasVideo, frames.isEmpty else { return }
        let generator = AVAssetImageGenerator(asset: clip.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 160)
        let count = 8
        var result: [UIImage] = []
        for index in 0..<count {
            let seconds = durationSeconds * (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cgImage = try? await generator.image(at: time).image {
                result.append(UIImage(cgImage: cgImage))
            }
        }
        frames = result
    }

    private func timeLabel(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let remainder = clamped - Double(minutes * 60)
        return minutes > 0
            ? String(format: "%d:%04.1f", minutes, remainder)
            : String(format: "%.1f s", remainder)
    }
}

/// Kuvat-appin trimmausidiomi: filminauha, keltainen kehys ja vedettävät
/// kahvat molemmissa päissä. Ääniklipille filminauhan tilalla on aaltomuoto.
struct FilmstripTrimView: View {
    let duration: Double
    let frames: [UIImage]
    let waveform: [Float]
    @Binding var start: Double
    @Binding var end: Double

    private let handleWidth: CGFloat = 22
    private let stripHeight: CGFloat = 56
    private let minimumLength = 0.1

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - 2 * handleWidth)
            let x0 = handleWidth + usable * CGFloat(start / duration)
            let x1 = handleWidth + usable * CGFloat(end / duration)

            ZStack(alignment: .topLeading) {
                Group {
                    if frames.isEmpty {
                        WaveformView(samples: waveform)
                            .padding(.vertical, 8)
                            .background(.quaternary.opacity(0.5))
                    } else {
                        HStack(spacing: 0) {
                            ForEach(frames.indices, id: \.self) { index in
                                Image(uiImage: frames[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: usable / CGFloat(frames.count), height: stripHeight)
                                    .clipped()
                            }
                        }
                    }
                }
                .frame(width: usable, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(x: handleWidth)

                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(width: max(0, x0 - handleWidth), height: stripHeight)
                    .offset(x: handleWidth)
                Rectangle()
                    .fill(.black.opacity(0.5))
                    .frame(width: max(0, handleWidth + usable - x1), height: stripHeight)
                    .offset(x: x1)

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.yellow, lineWidth: 3)
                    .frame(width: max(2 * handleWidth, x1 - x0 + 2 * handleWidth), height: stripHeight)
                    .offset(x: x0 - handleWidth)

                handle(systemImage: "chevron.compact.left")
                    .offset(x: x0 - handleWidth)
                    .gesture(dragGesture(usable: usable, isStart: true))
                handle(systemImage: "chevron.compact.right")
                    .offset(x: x1)
                    .gesture(dragGesture(usable: usable, isStart: false))
            }
            .coordinateSpace(name: "trimstrip")
        }
        .frame(height: stripHeight)
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(.yellow)
            .frame(width: handleWidth, height: stripHeight)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.black)
            }
            .contentShape(Rectangle())
    }

    private func dragGesture(usable: CGFloat, isStart: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("trimstrip"))
            .onChanged { value in
                let seconds = Double((value.location.x - handleWidth) / usable) * duration
                if isStart {
                    start = min(max(0, seconds), end - minimumLength)
                } else {
                    end = max(min(duration, seconds), start + minimumLength)
                }
            }
    }
}
