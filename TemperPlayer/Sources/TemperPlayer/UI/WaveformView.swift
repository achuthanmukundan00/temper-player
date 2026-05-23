import SwiftUI
import AVFAudio

struct WaveformView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    @State private var waveformBars: [CGFloat] = []
    @State private var isLoadingWaveform = false
    private let barCount = 80

    var body: some View {
        VStack(spacing: 4 * uiScale) {
            HStack {
                Text("WAVEFORM")
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
                if isLoadingWaveform {
                    Text("analyzing...")
                        .font(.system(size: 8 * uiScale, design: .monospaced))
                        .foregroundColor(Color(white: 0.2))
                }
            }

            GeometryReader { geo in
                let bars = waveformBars
                let barWidth = max(1, (geo.size.width - 1.5 * CGFloat(barCount - 1)) / CGFloat(barCount))

                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.02))

                    HStack(alignment: .center, spacing: 1.5) {
                        ForEach(bars.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 0.5)
                                .fill(barColor(for: i, total: barCount))
                                .frame(width: barWidth, height: max(2, bars[i] * (geo.size.height - 8 * uiScale)))
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .center)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            playerState.currentTime = p * playerState.duration
                        }
                        .onEnded { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            playback.seek(to: p * playerState.duration)
                        }
                )
            }
            .frame(height: 60 * uiScale)
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(white: 0.06)))

            if playerState.duration > 0 {
                timeLabelsView
            }
        }
        .onAppear { loadWaveform() }
        .onChange(of: playerState.currentTrack?.id) { _, _ in loadWaveform() }
    }

    private var timeLabelsView: some View {
        HStack(spacing: 0) {
            Text(playerState.timeString)
                .font(.system(size: 8 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.2))

            let labels = dynamicTimeLabels(duration: playerState.duration, count: 4)
            ForEach(labels, id: \.self) { label in
                Spacer()
                Text(label)
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.15))
            }

            Spacer()
            Text(playerState.durationString)
                .font(.system(size: 8 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.2))
        }
        .padding(.horizontal, 4 * uiScale)
    }

    private func dynamicTimeLabels(duration: Double, count: Int) -> [String] {
        stride(from: 1, through: count, by: 1).map { i in
            let t = duration * Double(i) / Double(count + 1)
            let m = Int(t) / 60; let s = Int(t) % 60
            return String(format: "%d:%02d", m, s)
        }
    }

    private func barColor(for index: Int, total: Int) -> Color {
        let p = playerState.duration > 0 ? playerState.currentTime / playerState.duration : 0
        return CGFloat(index) / CGFloat(total) <= p ? .white : Color(white: 0.12)
    }

    private func loadWaveform() {
        guard let track = playerState.currentTrack else {
            waveformBars = []
            return
        }
        isLoadingWaveform = true
        waveformBars = Self.generatePlaceholderBars(count: barCount)

        Task.detached(priority: .background) {
            let computed = Self.computeWaveformBars(path: track.path, barCount: 80)
            let dbBars = computed.isEmpty ? Self.generatePlaceholderBars(count: 80) : computed.map { Self.amplitudeToDbHeight($0) }
            await MainActor.run {
                self.waveformBars = dbBars
                self.isLoadingWaveform = false
            }
        }
    }

    nonisolated private static func computeWaveformBars(path: String, barCount: Int) -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = file.length
        let channels = Int(format.channelCount)
        let framesPerBar = max(1, totalFrames / Int64(barCount))
        let chunkFrames: AVAudioFrameCount = 32768

        file.framePosition = 0

        var peaks = Array(repeating: Float(0), count: barCount)
        var frameIndex: Int64 = 0

        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            try? file.read(into: buffer)
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }

            for f in 0..<Int(buffer.frameLength) {
                let barIdx = min(barCount - 1, Int(frameIndex / framesPerBar))
                for ch in 0..<channels {
                    peaks[barIdx] = max(peaks[barIdx], abs(data[ch][f]))
                }
                frameIndex += 1
            }
        }

        return peaks
    }

    nonisolated private static func amplitudeToDbHeight(_ peak: Float) -> CGFloat {
        let dbFloor: Float = -60
        let db = 20 * log10(max(0.00003, peak))
        return CGFloat(max(0, (db - dbFloor) / (-dbFloor)))
    }

    nonisolated private static func generatePlaceholderBars(count: Int) -> [CGFloat] {
        (0..<count).map { i in
            let phase = sin(Double(i) * 0.3) * 0.4 + 0.5
            let noise = sin(Double(i) * 1.7) * 0.15 + 0.15
            return CGFloat(max(0.05, phase + noise))
        }
    }
}
