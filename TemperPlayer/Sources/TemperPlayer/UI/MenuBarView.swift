import SwiftUI

struct MenuBarView: View {
    let playerState: PlayerState
    let audioManager: AudioManager
    let playback: PlaybackController
    let library: Database
    let importService: ImportService

    var body: some View {
        HStack(spacing: 12) {
            artworkView
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                if let track = playerState.currentTrack {
                    Text(track.title ?? track.path.components(separatedBy: "/").last ?? "unknown")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(track.artist ?? "Unknown Artist")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.55))
                        .lineLimit(1)

                    Text(formatInfo(track))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(Color(white: 0.35))
                        .lineLimit(1)
                } else {
                    Text("TemperPlayer")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(white: 0.4))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if playerState.currentTrack != nil {
                HStack(spacing: 6) {
                    button("\u{23EE}", action: previousTrack)
                    button(playerState.isPlaying ? "\u{23F8}" : "\u{25B6}", action: togglePlay)
                    button("\u{23ED}", action: nextTrack)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 340)
    }

    @ViewBuilder
    private var artworkView: some View {
        if let track = playerState.currentTrack,
           let data = importService.artwork(for: track.id),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .cornerRadius(4)
        } else {
            Rectangle()
                .fill(Color(white: 0.1))
                .frame(width: 48, height: 48)
                .cornerRadius(4)
                .overlay(
                    Text("\u{266A}")
                        .font(.system(size: 18))
                        .foregroundColor(Color(white: 0.3))
                )
        }
    }

    private func button(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .background(Color(white: 0.12))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func togglePlay() {
        if playerState.isPlaying {
            playback.pause()
        } else {
            playback.resume()
        }
    }

    private func previousTrack() {
        playback.previous()
    }

    private func nextTrack() {
        playback.next()
    }

    private func formatInfo(_ track: Track) -> String {
        var parts: [String] = [track.format.uppercased()]
        if track.sampleRate >= 1000 {
            parts.append("\(track.sampleRate / 1000).\(track.sampleRate % 1000 / 100)k")
        } else {
            parts.append("\(track.sampleRate)")
        }
        parts.append("\(track.bitDepth)bit")
        return parts.joined(separator: " | ")
    }
}
