import SwiftUI
import CTemperPlayer

struct InspectorView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    let hoveredTrackId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "BUFFER")
            if let track = displayedTrack {
                Text(track.path)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(3)
            } else {
                Text("no buffer loaded")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }

            SectionHeader(title: "STREAM")
            if let track = displayedTrack {
                StreamInfoView(track: track)
            } else {
                Text("\u{2014}").font(.system(size: 9, design: .monospaced)).foregroundColor(Color(white: 0.2))
            }

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color(white: 0.1))
                    .frame(width: 20, height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color(white: 0.06)))
                Text("artwork").font(.system(size: 8, design: .monospaced)).foregroundColor(Color(white: 0.25))
            }

            SectionHeader(title: "QUEUE")
            VStack(alignment: .leading, spacing: 2) {
                if let track = playerState.currentTrack {
                    HStack(spacing: 4) {
                        Text("\u{25B6}").foregroundColor(.white).font(.system(size: 8, design: .monospaced))
                        Text(track.title ?? "untitled").foregroundColor(Color(white: 0.7))
                    }
                }
                ForEach(playerState.queue.prefix(3)) { track in
                    Text("  \(track.title ?? "untitled")").foregroundColor(Color(white: 0.3))
                }
                if playerState.queue.count > 3 {
                    Text("  +\(playerState.queue.count - 3) more").foregroundColor(Color(white: 0.2))
                }
            }
            .font(.system(size: 9, design: .monospaced))

            Spacer()

            HStack {
                Text("PID \(ProcessInfo.processInfo.processIdentifier)")
                    .font(.system(size: 7, design: .monospaced))
                Spacer()
            }
            .foregroundColor(Color(white: 0.15))
            .padding(.top, 4)
            .overlay(Divider().frame(maxWidth: .infinity).foregroundColor(Color(white: 0.04)), alignment: .top)
        }
        .padding(12)
        .font(.system(size: 10, design: .monospaced))
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private var displayedTrack: Track? {
        if let id = hoveredTrackId { return library.tracks.first { $0.id == id } }
        return playerState.currentTrack
    }
}

struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 8, design: .monospaced))
            .foregroundColor(Color(white: 0.35))
            .tracking(1.5)
            .padding(.top, 4)
    }
}

struct StreamInfoView: View {
    let track: Track

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            KeyValueRow(key: "format", value: track.format, color: .white)
            KeyValueRow(key: "sample rate", value: formatNum(track.sampleRate), color: .white)
            KeyValueRow(key: "bit depth", value: "\(track.bitDepth)", color: .white)
            KeyValueRow(key: "channels", value: "\(track.channels)", color: .white)
            KeyValueRow(key: "duration", value: durationString(track.duration), color: .white)

            Color(white: 0.08).frame(height: 1)

            if let l = track.lufs { KeyValueRow(key: "loudness", value: String(format: "%.1f LUFS", l), color: .white) }
            if let tp = track.truePeak { KeyValueRow(key: "true peak", value: String(format: "%.1f dBTP", tp), color: .white) }
            if let l = track.lufs { KeyValueRow(key: "peak", value: String(format: "%.1f dB", l), color: .white) }
            if let dr = track.dynamicRange { KeyValueRow(key: "dynamic", value: String(format: "%.1f dB", dr), color: .white) }

            Color(white: 0.08).frame(height: 1)

            if let pc = track.phaseCorrelation {
                KeyValueRow(key: "phase", value: pc > 0.5 ? "ok" : (pc > 0 ? "warn" : "bad"),
                          color: pc > 0.5 ? Color(red: 0.4, green: 0.8, blue: 0.4) : (pc > 0 ? Color(red: 0.9, green: 0.7, blue: 0.3) : Color(red: 0.9, green: 0.3, blue: 0.3)))
                KeyValueRow(key: "corr", value: String(format: "%+.2f", pc), color: .white)
            }
            if let dc = track.dcOffset {
                let c = abs(dc) < 0.01 ? Color(white: 0.6) : Color(red: 0.9, green: 0.7, blue: 0.3)
                KeyValueRow(key: "dc offset", value: String(format: "%+.3f%%", dc), color: c)
            }
        }
        .font(.system(size: 9, design: .monospaced))
    }

    private func formatNum(_ n: Int) -> String {
        n >= 1000 ? "\(n / 1000).\(n / 100 % 10)k" : "\(n)"
    }

    private func durationString(_ d: Double) -> String {
        let m = Int(d) / 60; let s = Int(d) % 60
        return String(format: "%d:%02d.%d", m, s, Int(d * 10) % 10)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var color: Color = Color(white: 0.7)
    var body: some View {
        HStack(spacing: 0) {
            Text(key).foregroundColor(Color(white: 0.35)).frame(width: 72, alignment: .trailing)
            Text(" ")
            Text(value).foregroundColor(color)
        }
    }
}
