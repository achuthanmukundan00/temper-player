import SwiftUI

struct CompactPlayerView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var library: Database
    @Environment(\.uiScale) var uiScale
    @ObservedObject private var importService = ImportService.shared

    var body: some View {
        VStack(spacing: 16 * uiScale) {
            Spacer()

            if let track = playerState.currentTrack {
                artworkView(for: track)
                    .frame(width: 100 * uiScale, height: 100 * uiScale)

                VStack(spacing: 3 * uiScale) {
                    Text(track.title ?? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14 * uiScale, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist ?? "Unknown Artist")
                        .font(.system(size: 11 * uiScale, design: .monospaced))
                        .foregroundColor(Color(white: 0.5))
                        .lineLimit(1)
                }

                PlayBar()
                    .frame(maxWidth: 320 * uiScale)

                HStack(spacing: 18 * uiScale) {
                    compactButton("\u{23EE}") { playback.previous() }
                    compactButton("\u{25C0}") { playback.seek(by: -5) }

                    ZStack {
                        Circle()
                            .stroke(Color(white: 0.2), lineWidth: 1)
                            .frame(width: 34 * uiScale, height: 34 * uiScale)
                        Text(playerState.isPlaying ? "\u{25A0}" : "\u{25B6}")
                            .font(.system(size: 13 * uiScale, design: .monospaced))
                            .foregroundColor(.white)
                    }
                    .onTapGesture { playback.togglePlayPause() }

                    compactButton("\u{25B6}") { playback.seek(by: 5) }
                    compactButton("\u{23ED}") { playback.next() }
                }
            } else {
                VStack(spacing: 6 * uiScale) {
                    Text("TemperPlayer")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(white: 0.3))
                    Text("load a track in full mode")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(white: 0.2))
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.black)
    }

    @ViewBuilder
    private func artworkView(for track: Track) -> some View {
        if let data = importService.artwork(for: track.id), let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipped()
                .overlay(Rectangle().stroke(Color(white: 0.12), lineWidth: 1))
        } else {
            Rectangle()
                .fill(Color(white: 0.08))
                .overlay(Rectangle().stroke(Color(white: 0.12), lineWidth: 1))
        }
    }

    private func compactButton(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 11 * uiScale, design: .monospaced))
            .foregroundColor(Color(white: 0.5))
            .frame(width: 26 * uiScale, height: 26 * uiScale)
            .onTapGesture { action() }
    }
}
