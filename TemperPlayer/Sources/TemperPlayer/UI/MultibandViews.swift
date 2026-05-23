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
                    let positive = analyzer.waveformPositive
                    let negative = analyzer.waveformNegative
                    let count = min(sub.count, lowMid.count, mid.count, upperMid.count, high.count, positive.count, negative.count)
                    guard count > 1 else { return }

                    let visibleCount = max(count, analyzer.waveformVisiblePointCount)
                    let xStep = size.width / CGFloat(max(1, visibleCount))
                    let scrollOffset = CGFloat(analyzer.waveformPhase) * xStep
                    let startSlot = visibleCount - count

                    func clampedBand(_ values: [Float], _ index: Int) -> CGFloat {
                        max(0, min(1, CGFloat(values[index])))
                    }

                    func envelopePath(x0: CGFloat, x1: CGFloat, top0: CGFloat, top1: CGFloat, bottom0: CGFloat, bottom1: CGFloat) -> Path {
                        var path = Path()
                        path.move(to: CGPoint(x: x0, y: top0))
                        path.addLine(to: CGPoint(x: x1, y: top1))
                        path.addLine(to: CGPoint(x: x1, y: bottom1))
                        path.addLine(to: CGPoint(x: x0, y: bottom0))
                        path.closeSubpath()
                        return path
                    }

                    for index in 0..<(count - 1) {
                        let next = index + 1
                        let s = (clampedBand(sub, index) + clampedBand(sub, next)) * 0.5
                        let lm = (clampedBand(lowMid, index) + clampedBand(lowMid, next)) * 0.5
                        let m = (clampedBand(mid, index) + clampedBand(mid, next)) * 0.5
                        let um = (clampedBand(upperMid, index) + clampedBand(upperMid, next)) * 0.5
                        let h = (clampedBand(high, index) + clampedBand(high, next)) * 0.5
                        let x0 = CGFloat(startSlot + index) * xStep - scrollOffset
                        let x1 = CGFloat(startSlot + next) * xStep - scrollOffset
                        guard x1 >= 0, x0 <= size.width else { continue }

                        let pos0 = max(0, min(1, CGFloat(positive[index])))
                        let pos1 = max(0, min(1, CGFloat(positive[next])))
                        let neg0 = max(-1, min(0, CGFloat(negative[index])))
                        let neg1 = max(-1, min(0, CGFloat(negative[next])))
                        let minHalfHeight = max(0.45, 0.35 * uiScale)
                        let top0 = min(centerY - pos0 * usableHeight, centerY - minHalfHeight)
                        let top1 = min(centerY - pos1 * usableHeight, centerY - minHalfHeight)
                        let bottom0 = max(centerY - neg0 * usableHeight, centerY + minHalfHeight)
                        let bottom1 = max(centerY - neg1 * usableHeight, centerY + minHalfHeight)

                        let transient = transientStrength(red: s, orange: lm, green: m, cyan: um, blue: h)
                        if transient > 0.03 {
                            let lift = 1.04 + transient * 0.34
                            let transientTop0 = centerY - min(1, pos0 * lift + transient * 0.02) * usableHeight
                            let transientTop1 = centerY - min(1, pos1 * lift + transient * 0.02) * usableHeight
                            let transientBottom0 = centerY - max(-1, neg0 * lift - transient * 0.02) * usableHeight
                            let transientBottom1 = centerY - max(-1, neg1 * lift - transient * 0.02) * usableHeight
                            let transientColor = waveformColor(red: s, orange: lm, green: m, cyan: um, blue: h, transient: transient)
                            context.fill(
                                envelopePath(
                                    x0: x0,
                                    x1: x1,
                                    top0: transientTop0,
                                    top1: transientTop1,
                                    bottom0: transientBottom0,
                                    bottom1: transientBottom1
                                ),
                                with: .color(transientColor.opacity(0.32 + Double(transient) * 0.26))
                            )
                        }

                        let color = waveformColor(red: s, orange: lm, green: m, cyan: um, blue: h, transient: transient)
                        context.fill(
                            envelopePath(x0: x0, x1: x1, top0: top0, top1: top1, bottom0: bottom0, bottom1: bottom1),
                            with: .color(color.opacity(0.94))
                        )
                    }
                }
            }
            .frame(height: 52 * uiScale)
            .background(Color(white: 0.02))
            .overlay(Rectangle().stroke(Color(white: 0.06)))
        }
    }

    private func waveformColor(red: CGFloat, orange: CGFloat, green: CGFloat, cyan: CGFloat, blue: CGFloat, transient: CGFloat) -> Color {
        let total = max(0.001, red + orange + green + cyan + blue)
        let rWeight = red / total
        let oWeight = orange / total
        let gWeight = green / total
        let cWeight = cyan / total
        let bWeight = blue / total

        var r = rWeight * 1.00 + oWeight * 0.92 + gWeight * 0.46 + cWeight * 0.18 + bWeight * 0.48
        var g = rWeight * 0.05 + oWeight * 0.46 + gWeight * 1.00 + cWeight * 0.54 + bWeight * 0.10
        var b = rWeight * 0.08 + oWeight * 0.04 + gWeight * 0.06 + cWeight * 1.00 + bWeight * 1.00

        let lowPresence = min(1, rWeight + oWeight * 0.7)
        let highPresence = min(1, cWeight * 0.75 + bWeight)
        let lowHighBlend = min(lowPresence, highPresence) * min(1, (cyan + blue) * 1.35)
        r += lowHighBlend * 0.10
        g -= lowHighBlend * 0.16
        b += lowHighBlend * 0.48

        let average = (r + g + b) / 3
        let saturation: CGFloat = 1.45
        r = average + (r - average) * saturation
        g = average + (g - average) * saturation
        b = average + (b - average) * saturation

        let lift = min(0.12, max(red, max(orange, max(green, max(cyan, blue)))) * 0.08 + transient * 0.10)

        return Color(
            red: min(1, max(0, r + lift)),
            green: min(1, max(0, g + lift)),
            blue: min(1, max(0, b + lift))
        )
    }

    private func transientStrength(red: CGFloat, orange: CGFloat, green: CGFloat, cyan: CGFloat, blue: CGFloat) -> CGFloat {
        let strongest = max(red, max(orange, max(green, max(cyan, blue))))
        return max(0, min(1, (strongest - 0.55) * 1.7))
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
            .frame(height: 30 * uiScale)

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
        .padding(.top, 5 * uiScale)
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
            .frame(height: 76 * uiScale)
            .overlay(Rectangle().stroke(Color(white: 0.06)))
        }
        .frame(maxWidth: .infinity)
    }
}
