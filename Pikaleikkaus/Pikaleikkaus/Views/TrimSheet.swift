import AVFoundation
import SwiftUI

/// Klipin trimmaus ja äänenvoimakkuus. Muutokset kirjoitetaan malliin vasta
/// ”Valmis”-painikkeesta, jotta esikatselua ei rakenneta joka liu'utuksella.
struct TrimSheet: View {
    let clip: Clip
    let onSave: (Clip) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var startSeconds: Double
    @State private var endSeconds: Double
    @State private var volume: Double

    private let durationSeconds: Double
    private let minimumLength = 0.1

    init(clip: Clip, onSave: @escaping (Clip) -> Void) {
        self.clip = clip
        self.onSave = onSave
        self.durationSeconds = clip.duration.seconds
        _startSeconds = State(initialValue: clip.trimStart.seconds)
        _endSeconds = State(initialValue: clip.trimEnd.seconds)
        _volume = State(initialValue: Double(clip.volume))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trimmaus") {
                    LabeledContent("Alku", value: timeLabel(startSeconds))
                    Slider(value: $startSeconds, in: 0...durationSeconds)
                        .onChange(of: startSeconds) { _, newValue in
                            if newValue > endSeconds - minimumLength {
                                startSeconds = max(0, endSeconds - minimumLength)
                            }
                        }

                    LabeledContent("Loppu", value: timeLabel(endSeconds))
                    Slider(value: $endSeconds, in: 0...durationSeconds)
                        .onChange(of: endSeconds) { _, newValue in
                            if newValue < startSeconds + minimumLength {
                                endSeconds = min(durationSeconds, startSeconds + minimumLength)
                            }
                        }

                    LabeledContent("Kesto", value: timeLabel(endSeconds - startSeconds))
                }

                Section("Ääni") {
                    HStack {
                        Image(systemName: "speaker.wave.1")
                        Slider(value: $volume, in: 0...1)
                        Image(systemName: "speaker.wave.3")
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
                        onSave(updated)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func timeLabel(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return minutes > 0
            ? String(format: "%d:%04.1f", minutes, remainder)
            : String(format: "%.1f s", remainder)
    }
}
