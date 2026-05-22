import SwiftUI

struct WaveformView: View {
    @EnvironmentObject var playerState: PlayerState
    @State private var waveformBars: [CGFloat] = []

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("WAVEFORM")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            GeometryReader { geo in
                let barCount = max(Int(geo.size.width / 3), 20)
                let bars = waveformBars.isEmpty ? generateSampleBars(count: barCount) : waveformBars

                HStack(alignment: .center, spacing: 1.5) {
                    ForEach(bars.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(barColor(for: i, total: bars.count, progress: geo.size.width))
                            .frame(
                                width: max(1, (geo.size.width - CGFloat(bars.count)) / CGFloat(bars.count)),
                                height: max(2, bars[i] * (geo.size.height - 8))
                            )
                    }
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 52)
            .background(Color(white: 0.02))
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(white: 0.06)))

            HStack(spacing: 0) {
                Text(playerState.timeString)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
                Spacer()
                Text("0:15").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(white: 0.15))
                Spacer()
                Text("0:30").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(white: 0.15))
                Spacer()
                Text("0:45").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(white: 0.15))
                Spacer()
                Text(playerState.durationString)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }
            .padding(.horizontal, 4)
        }
    }

    private func barColor(for index: Int, total: Int, progress: CGFloat) -> Color {
        let p = playerState.duration > 0 ? playerState.currentTime / playerState.duration : 0
        return CGFloat(index) / CGFloat(total) <= p ? .white : Color(white: 0.12)
    }

    private func generateSampleBars(count: Int) -> [CGFloat] {
        var bars: [CGFloat] = []
        for i in 0..<count {
            let phase = sin(Double(i) * 0.3) * 0.4 + 0.5
            let noise = Double.random(in: 0.1...0.3)
            bars.append(CGFloat(phase + noise))
        }
        return bars
    }
}
