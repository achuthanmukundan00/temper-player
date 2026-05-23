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

                    guard analyzer.waveformBands.count >= 6 else { return }
                    let sub = analyzer.waveformBands[0]
                    let bass = analyzer.waveformBands[1]
                    let lowMid = analyzer.waveformBands[2]
                    let mid = analyzer.waveformBands[3]
                    let upperMid = analyzer.waveformBands[4]
                    let high = analyzer.waveformBands[5]
                    let positive = analyzer.waveformPositive
                    let negative = analyzer.waveformNegative
                    let count = min(sub.count, bass.count, lowMid.count, mid.count, upperMid.count, high.count, positive.count, negative.count)
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
                        let b = (clampedBand(bass, index) + clampedBand(bass, next)) * 0.5
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

                        let transient = transientStrength(red: s, orange: b, yellow: lm, green: m, cyan: um, blue: h)

                        let color = waveformColor(red: s, orange: b, yellow: lm, green: m, cyan: um, blue: h, transient: transient)
                        context.fill(
                            envelopePath(
                                x0: x0,
                                x1: x1,
                                top0: centerY - pos0 * usableHeight,
                                top1: centerY - pos1 * usableHeight,
                                bottom0: centerY - neg0 * usableHeight,
                                bottom1: centerY - neg1 * usableHeight
                            ),
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

    private func waveformColor(red: CGFloat, orange: CGFloat, yellow: CGFloat, green: CGFloat, cyan: CGFloat, blue: CGFloat, transient: CGFloat) -> Color {
        let centers: [CGFloat] = [55, 160, 350, 850, 2600, 10000]
        let rawAmps = [red, orange, yellow, green, cyan, blue]
        let displayGainsDb = centers.enumerated().map { index, frequency in
            let weighting = index == 0 ? 0 : aWeightingDb(frequency: frequency) * 0.28
            let highTaper: CGFloat = index >= 3 ? CGFloat(index - 2) * 1.0 : 0
            let colorBiasDb: [CGFloat] = [3.0, 1.0, 1.0, -4.0, -1.0, 4.0]
            return weighting - highTaper + colorBiasDb[index]
        }
        let floorDb: CGFloat = -56

        var rawDbs: [CGFloat] = []
        var compensatedDbs: [CGFloat] = []
        for i in rawAmps.indices {
            let amp = max(1e-6, rawAmps[i])
            let rawDb = 20 * log10(amp)
            let compensationDb = displayGainsDb[i]
            rawDbs.append(rawDb)
            compensatedDbs.append(rawDb + compensationDb)
        }

        let activity = max(red, max(orange, max(yellow, max(green, max(cyan, blue)))))
        let activityDb = 20 * log10(max(1e-6, activity))
        let brightness = pow(max(0, min(1, (activityDb - floorDb) / (-floorDb))), 0.55)

        let maxDb = compensatedDbs.max() ?? -60
        var rawWeights = compensatedDbs.map { pow(CGFloat(10), max(-42, $0 - maxDb) / 12) }

        let yellowMargin = compensatedDbs[2] - max(compensatedDbs[3], max(compensatedDbs[4], compensatedDbs[5]))
        rawWeights[2] *= 0.52 + 0.48 * smoothstep(edge0: -4, edge1: 6, value: yellowMargin)

        let weightSum = max(0.001, rawWeights.reduce(0, +))
        let weights = rawWeights.map { $0 / weightSum }

        // Spectral spread (kept for whiteBlend)
        var centroidLogHz: CGFloat = 0
        for index in weights.indices {
            centroidLogHz += log2(centers[index]) * weights[index]
        }
        var spread: CGFloat = 0
        for index in weights.indices {
            let distance = log2(centers[index]) - centroidLogHz
            spread += distance * distance * weights[index]
        }
        spread = sqrt(spread)

        // Color from the TWO strongest bands (not centroid).
        // Centroid breaks bimodal distributions: bass+treble → middle → yellow/green.
        // Two-band lerp gives bass+treble → red↔blue = purple/pink.
        let sorted = weights.enumerated().sorted { $0.element > $1.element }
        let primary   = sorted[0]
        let secondary = sorted[1]
        let blend = secondary.element / max(0.001, primary.element + secondary.element)
        let (r1, g1, b1) = spectralColor(logHz: log2(centers[primary.offset]))
        let (r2, g2, b2) = spectralColor(logHz: log2(centers[secondary.offset]))
        var r = r1 + (r2 - r1) * blend
        var g = g1 + (g2 - g1) * blend
        var b = b1 + (b2 - b1) * blend
        let avg = (r + g + b) / 3
        let saturation: CGFloat = 1.18
        r = avg + (r - avg) * saturation
        g = avg + (g - avg) * saturation
        b = avg + (b - avg) * saturation

        let lowWeight = weights[0] + weights[1]
        let midWeight = weights[2] + weights[3]
        let highWeight = weights[4] + weights[5]
        let balancedSpan = min(
            smoothstep(edge0: 0.18, edge1: 0.42, value: lowWeight),
            min(
                smoothstep(edge0: 0.14, edge1: 0.34, value: midWeight),
                smoothstep(edge0: 0.18, edge1: 0.42, value: highWeight)
            )
        )
        let wideSpan = smoothstep(edge0: 1.05, edge1: 2.20, value: spread)
        let whiteBlend = min(0.58, balancedSpan * wideSpan * smoothstep(edge0: 0.68, edge1: 0.98, value: transient))

        r = r * (1 - whiteBlend) + whiteBlend
        g = g * (1 - whiteBlend) + whiteBlend
        b = b * (1 - whiteBlend) + whiteBlend

        let dimFactor = min(1, 0.10 + brightness * 0.92 + transient * 0.16 + whiteBlend * 0.40)
        let lift = transient * 0.03 + whiteBlend * 0.18

        return Color(
            red:   min(1, max(0, r * dimFactor + lift)),
            green: min(1, max(0, g * dimFactor + lift)),
            blue:  min(1, max(0, b * dimFactor + lift))
        )
    }

    private func transientStrength(red: CGFloat, orange: CGFloat, yellow: CGFloat, green: CGFloat, cyan: CGFloat, blue: CGFloat) -> CGFloat {
        let strongest = max(red, max(orange, max(yellow, max(green, max(cyan, blue)))))
        let total = red + orange + yellow + green + cyan + blue
        let peakHit = smoothstep(edge0: 0.38, edge1: 0.82, value: strongest)
        let broadbandHit = smoothstep(edge0: 0.72, edge1: 1.90, value: total)
        return max(peakHit, broadbandHit * 0.92)
    }

    private func smoothstep(edge0: CGFloat, edge1: CGFloat, value: CGFloat) -> CGFloat {
        let x = max(0, min(1, (value - edge0) / max(0.0001, edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }

    private func aWeightingDb(frequency: CGFloat) -> CGFloat {
        let f2 = frequency * frequency
        let f4 = f2 * f2
        let c20 = CGFloat(20.6 * 20.6)
        let c108 = CGFloat(107.7 * 107.7)
        let c738 = CGFloat(737.9 * 737.9)
        let c12200 = CGFloat(12_200 * 12_200)
        let numerator = c12200 * f4
        let denominator = (f2 + c20) * sqrt((f2 + c108) * (f2 + c738)) * (f2 + c12200)
        return 2.0 + 20 * log10(max(1e-12, numerator / denominator))
    }

    private func spectralColor(logHz: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
        let stops: [(hz: CGFloat, r: CGFloat, g: CGFloat, b: CGFloat)] = [
            (55, 1.00, 0.04, 0.02),
            (160, 1.00, 0.36, 0.02),
            (350, 1.00, 0.88, 0.04),
            (850, 0.20, 0.96, 0.22),
            (2_600, 0.02, 0.92, 1.00),
            (10_000, 0.16, 0.40, 1.00)
        ]

        if logHz <= log2(stops[0].hz) {
            let stop = stops[0]
            return (stop.r, stop.g, stop.b)
        }

        for index in 0..<(stops.count - 1) {
            let lower = stops[index]
            let upper = stops[index + 1]
            let lowerLog = log2(lower.hz)
            let upperLog = log2(upper.hz)
            guard logHz <= upperLog else { continue }
            let t = max(0, min(1, (logHz - lowerLog) / (upperLog - lowerLog)))
            return (
                lower.r + (upper.r - lower.r) * t,
                lower.g + (upper.g - lower.g) * t,
                lower.b + (upper.b - lower.b) * t
            )
        }

        let stop = stops[stops.count - 1]
        return (stop.r, stop.g, stop.b)
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
