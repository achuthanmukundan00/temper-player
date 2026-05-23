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
                            with: .color(barColor(at: bi, total: barCount).opacity(Double(0.28 + 0.72 * amp)))
                        )
                    }
                }
            }
            .frame(height: 70 * uiScale)
            .background(Color(white: 0.02))
            .overlay(Rectangle().stroke(Color(white: 0.08)))

            HStack(spacing: 0) {
                Text("20Hz").frame(width: 40 * uiScale, alignment: .leading)
                Spacer()
                Text("250Hz")
                Spacer()
                Text("2kHz")
                Spacer()
                Text("20kHz")
            }
            .font(.system(size: 7 * uiScale, design: .monospaced))
            .foregroundColor(Color(white: 0.2))
            .padding(.horizontal, 4 * uiScale)
        }
    }

    private func barColor(at index: Int, total: Int) -> Color {
        let t = Double(index) / Double(max(1, total - 1))
        let r, g, b: Double
        if t < 0.5 {
            let u = t / 0.5
            r = 1 - u
            g = u
            b = 0
        } else {
            let u = (t - 0.5) / 0.5
            r = 0
            g = 1 - u
            b = u
        }
        return Color(red: r, green: g, blue: b)
    }
}
