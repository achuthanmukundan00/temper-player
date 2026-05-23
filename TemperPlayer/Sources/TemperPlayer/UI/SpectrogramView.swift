import SwiftUI

struct SpectrogramView: View {
    @EnvironmentObject var analyzer: RealtimeAnalyzer
    @Environment(\.uiScale) var uiScale

    var body: some View {
        VStack(spacing: 2 * uiScale) {
            HStack {
                Text("SPECTRUM")
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            GeometryReader { geo in
                let bars = analyzer.spectrumBars
                let barCount = max(1, bars.count)
                let barW = geo.size.width / CGFloat(barCount)
                let sampleRate = analyzer.sampleRate

                Canvas(opaque: true) { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.02)))

                    for bi in 0..<barCount {
                        let amp = CGFloat(bi < bars.count ? bars[bi] : 0)
                        let x = CGFloat(bi) * barW
                        let barH = max(1, amp * size.height)
                        let rect = CGRect(
                            x: x,
                            y: size.height - barH,
                            width: max(1, barW - 0.6),
                            height: barH
                        )
                        context.fill(
                            Path(rect),
                            with: .color(
                                barColor(for: frequency(at: bi, total: barCount, sampleRate: sampleRate))
                                    .opacity(Double(0.28 + 0.72 * amp))
                            )
                        )
                    }
                }
            }
            .frame(height: 76 * uiScale)
            .background(Color(white: 0.02))
            .overlay(Rectangle().stroke(Color(white: 0.06)))

            HStack(spacing: 0) {
                Text("20Hz").foregroundColor(Color(white: 0.18)).frame(width: 40 * uiScale, alignment: .leading)
                Spacer()
                Text("250Hz").foregroundColor(Color(white: 0.25))
                Spacer()
                Text("600Hz").foregroundColor(Color(white: 0.25))
                Spacer()
                Text("1.3k").foregroundColor(Color(white: 0.25))
                Spacer()
                Text("5k").foregroundColor(Color(white: 0.25))
                Spacer()
                Text("20kHz").foregroundColor(Color(white: 0.18))
            }
            .font(.system(size: 7 * uiScale, design: .monospaced))
            .foregroundColor(Color(white: 0.2))
            .padding(.horizontal, 4 * uiScale)
        }
    }

    private func frequency(at index: Int, total: Int, sampleRate: Float) -> Double {
        let minHz = 30.0
        let maxHz = max(minHz + 1, min(Double(sampleRate) * 0.5, 20_000))
        let t = (Double(index) + 0.5) / Double(max(1, total))
        return pow(10, log10(minHz) + (log10(maxHz) - log10(minHz)) * t)
    }

    private func barColor(for frequency: Double) -> Color {
        let stops: [(hz: Double, r: Double, g: Double, b: Double)] = [
            (30, 1.00, 0.12, 0.08),
            (250, 1.00, 0.48, 0.05),
            (600, 0.22, 0.95, 0.24),
            (1_300, 0.08, 0.88, 1.00),
            (5_000, 0.18, 0.36, 1.00),
            (20_000, 0.18, 0.36, 1.00)
        ]

        if frequency <= stops[0].hz {
            return Color(red: stops[0].r, green: stops[0].g, blue: stops[0].b)
        }

        for index in 0..<(stops.count - 1) {
            let lower = stops[index]
            let upper = stops[index + 1]
            guard frequency <= upper.hz else { continue }
            let t = max(0, min(1, (log(frequency) - log(lower.hz)) / (log(upper.hz) - log(lower.hz))))
            return Color(
                red: lower.r + (upper.r - lower.r) * t,
                green: lower.g + (upper.g - lower.g) * t,
                blue: lower.b + (upper.b - lower.b) * t
            )
        }

        let last = stops[stops.count - 1]
        return Color(red: last.r, green: last.g, blue: last.b)
    }
}
