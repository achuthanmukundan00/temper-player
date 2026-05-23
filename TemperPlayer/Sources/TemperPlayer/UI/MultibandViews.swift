import SwiftUI

struct MultibandWaveformView: View {
    @EnvironmentObject var analyzer: RealtimeAnalyzer
    @Environment(\.uiScale) var uiScale

    var body: some View {
        VStack(spacing: 2 * uiScale) {
            HStack {
                Text("WAVE")
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            GeometryReader { geo in
                Canvas(opaque: true) { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.02)))

                    let centerY = size.height / 2
                    let usableHeight = size.height * 0.47

                    var zero = Path()
                    zero.move(to: CGPoint(x: 0, y: centerY))
                    zero.addLine(to: CGPoint(x: size.width, y: centerY))
                    context.stroke(zero, with: .color(Color(white: 0.08)), lineWidth: 0.5)

                    guard analyzer.waveformBands.count >= 5 else { return }
                    let sub = analyzer.waveformBands[0]
                    let lowMid = analyzer.waveformBands[1]
                    let mid = analyzer.waveformBands[2]
                    let upperMid = analyzer.waveformBands[3]
                    let high = analyzer.waveformBands[4]
                    let count = min(sub.count, lowMid.count, mid.count, upperMid.count, high.count)
                    guard count > 1 else { return }

                    let xStep = size.width / CGFloat(count)
                    let barWidth = max(1, xStep * 0.82)

                    for index in 0..<count {
                        let s = max(0, min(1, CGFloat(sub[index])))
                        let lm = max(0, min(1, CGFloat(lowMid[index])))
                        let m = max(0, min(1, CGFloat(mid[index])))
                        let um = max(0, min(1, CGFloat(upperMid[index])))
                        let h = max(0, min(1, CGFloat(high[index])))
                        let peak = min(1, pow(max(s * 0.98, max(lm * 0.95, max(m * 0.85, max(um * 0.88, h * 0.9)))), 0.82))
                        let height = max(1, peak * usableHeight)
                        let x = CGFloat(index) * xStep
                        let rect = CGRect(
                            x: x,
                            y: centerY - height,
                            width: barWidth,
                            height: height * 2
                        )

                        let color = waveformColor(sub: s, lowMid: lm, mid: m, upperMid: um, high: h)
                        context.fill(Path(rect), with: .color(color.opacity(0.9)))
                    }
                }
            }
            .frame(height: 46 * uiScale)
            .background(Color(white: 0.02))
            .overlay(Rectangle().stroke(Color(white: 0.08)))
        }
    }

    private func waveformColor(sub: CGFloat, lowMid: CGFloat, mid: CGFloat, upperMid: CGFloat, high: CGFloat) -> Color {
        let total = max(0.001, sub + lowMid + mid + upperMid + high)
        let sRatio = sub / total         // 0–200 Hz
        let lmRatio = lowMid / total     // 200–350 Hz
        let mRatio = mid / total         // 350–900 Hz
        let umRatio = upperMid / total   // 900–5000 Hz
        let hRatio = high / total        // 5000+ Hz

        // RED — sub presence, strong by 35%
        let redSub = max(0, (sRatio - 0.20) * 3.5)
        // ORANGE — from low-mid 200–350 Hz
        let redOrange = lmRatio * 0.70
        let greenOrange = lmRatio * 0.20
        // GREEN — bright green from 350–900 Hz
        let greenMid = mRatio * 1.8
        // CYAN — bright cyan from 900–5000 Hz
        let greenCyan = umRatio * 0.55
        let blueCyan = umRatio * 0.90
        // BLUE — from 5000+ Hz air
        let blueHigh = hRatio * 1.2

        return Color(
            red: min(1, redSub + redOrange),
            green: min(1, greenOrange + greenMid + greenCyan),
            blue: min(1, blueCyan + blueHigh)
        )
    }
}

struct MBLevelMeter: View {
    @EnvironmentObject var analyzer: RealtimeAnalyzer
    @Environment(\.uiScale) var uiScale

    private let labels = ["LOW", "MID", "HIGH"]
    private let colors: [Color] = [
        Color(red: 0.95, green: 0.24, blue: 0.18),
        Color(red: 0.45, green: 0.8, blue: 0.28),
        Color(red: 0.26, green: 0.48, blue: 0.95)
    ]

    var body: some View {
        VStack(spacing: 3 * uiScale) {
            HStack {
                Text("LEVEL")
                    .font(.system(size: 7 * uiScale, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.28))
                    .tracking(1.4)
                Spacer()
            }

            ForEach(0..<3, id: \.self) { index in
                GeometryReader { geo in
                    let level = CGFloat(index < analyzer.bandLevels.count ? analyzer.bandLevels[index] : 0)
                    HStack(spacing: 5 * uiScale) {
                        Text(labels[index])
                            .font(.system(size: 6 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.32))
                            .frame(width: 24 * uiScale, alignment: .leading)
                        ZStack(alignment: .leading) {
                            Rectangle().fill(Color(white: 0.07))
                            Rectangle()
                                .fill(colors[index])
                                .frame(width: max(1, geo.size.width - 29 * uiScale) * level)
                        }
                    }
                }
                .frame(height: 8 * uiScale)
            }
        }
    }
}

// MARK: - Multiband Correlation Meter

struct MBCorrelationMeter: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var analyzer: RealtimeAnalyzer
    @Environment(\.uiScale) var uiScale

    private let bandColors: [Color] = [
        Color(red: 1, green: 0, blue: 0),     // bass: red
        Color(red: 0, green: 1, blue: 0),     // mid:  green
        Color(red: 0, green: 0, blue: 1)      // high: blue
    ]

    var body: some View {
        VStack(spacing: 2 * uiScale) {
            HStack {
                Text("CORR")
                    .font(.system(size: 7 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            GeometryReader { geo in
                let centerX = geo.size.width / 2

                ForEach(0..<3, id: \.self) { bi in
                    let corr = bi < analyzer.bandCorrelations.count ? CGFloat(analyzer.bandCorrelations[bi]) : 0
                    let barLen = abs(corr) * (geo.size.width / 2 - 4)

                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(white: 0.08))
                            .frame(width: 1, height: geo.size.height)
                            .position(x: centerX, y: geo.size.height / 2)

                        RoundedRectangle(cornerRadius: 0.5)
                            .fill(bandColors[bi])
                            .frame(width: max(2, barLen), height: geo.size.height / 3 - 1)
                            .position(
                                x: corr >= 0 ? centerX + barLen / 2 : centerX - barLen / 2,
                                y: CGFloat(bi) * geo.size.height / 3 + geo.size.height / 6
                            )
                    }
                }
            }
            .frame(height: 28 * uiScale)

            HStack(spacing: 0) {
                Text("-1").frame(width: 20, alignment: .leading)
                Spacer()
                Text("0")
                Spacer()
                Text("+1").frame(width: 20, alignment: .trailing)
            }
            .font(.system(size: 6 * uiScale, design: .monospaced))
            .foregroundColor(Color(white: 0.2))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Multiband Stereo Goniometer

struct MBGoniometerView: View {
    @EnvironmentObject var analyzer: RealtimeAnalyzer
    @Environment(\.uiScale) var uiScale

    var body: some View {
        VStack(spacing: 2 * uiScale) {
            HStack {
                Text("GONIO")
                    .font(.system(size: 7 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
                    .tracking(1.5)
                Spacer()
            }

            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let radius = min(geo.size.width, geo.size.height) / 2 - 4
                let points = analyzer.goniometerPoints

                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                    context.stroke(Path { path in
                        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
                    }, with: .color(Color(white: 0.11)), lineWidth: 0.5)

                    var vert = Path()
                    vert.move(to: CGPoint(x: center.x, y: center.y - radius))
                    vert.addLine(to: CGPoint(x: center.x, y: center.y + radius))
                    context.stroke(vert, with: .color(Color(white: 0.09)), lineWidth: 0.5)

                    var horiz = Path()
                    horiz.move(to: CGPoint(x: center.x - radius, y: center.y))
                    horiz.addLine(to: CGPoint(x: center.x + radius, y: center.y))
                    context.stroke(horiz, with: .color(Color(white: 0.06)), lineWidth: 0.5)

                    guard !points.isEmpty else { return }

                    let scale = radius * 0.92
                    var trace = Path()
                    var didMove = false
                    for pt in points {
                        let left = max(-1, min(1, pt.x))
                        let right = max(-1, min(1, pt.y))
                        let mid = (left + right) * 0.5
                        let side = (left - right) * 0.5
                        let dx = side * scale
                        let dy = mid * scale
                        guard hypot(dx, dy) <= radius else { continue }
                        let x = center.x + dx
                        let y = center.y - dy
                        let mapped = CGPoint(x: x, y: y)
                        if didMove {
                            trace.addLine(to: mapped)
                        } else {
                            trace.move(to: mapped)
                            didMove = true
                        }
                    }

                    let corr = analyzer.correlation
                    let traceColor: Color = corr < -0.15
                        ? Color(red: 0.95, green: 0.25, blue: 0.22)
                        : Color(red: 0.45, green: 0.8, blue: 0.52)
                    context.stroke(trace, with: .color(traceColor.opacity(0.48)), lineWidth: 0.75)
                }
            }
            .frame(height: 72 * uiScale)
            .overlay(Rectangle().stroke(Color(white: 0.08)))
        }
        .frame(maxWidth: .infinity)
    }
}
