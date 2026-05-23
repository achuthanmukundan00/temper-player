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
                        .font(.system(size: 14 * uiScale, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(track.artist ?? "Unknown Artist")
                        .font(.system(size: 11 * uiScale))
                        .foregroundColor(Color(white: 0.5))
                        .lineLimit(1)
                }

                PlayBar()
                    .frame(maxWidth: 320 * uiScale)

                HStack(spacing: 18 * uiScale) {
                    compactButton(systemName: "backward.fill") { playback.previous() }
                    compactButton(systemName: "gobackward.5") { playback.seek(by: -5) }

                    Button(action: { playback.togglePlayPause() }) {
                        Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13 * uiScale, weight: .medium))
                            .foregroundColor(.white)
                            .frame(width: 34 * uiScale, height: 34 * uiScale)
                            .background(Circle().stroke(.secondary, lineWidth: 1))
                    }
                    .buttonStyle(.plain)

                    compactButton(systemName: "goforward.5") { playback.seek(by: 5) }
                    compactButton(systemName: "forward.fill") { playback.next() }
                }
            } else {
                VStack(spacing: 8 * uiScale) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.quaternary)
                    Text("TemperPlayer")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Color(white: 0.3))
                    Text("Load a track in the main window")
                        .font(.system(size: 10))
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
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.2))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.quaternary)
                )
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 0.5))
        }
    }

    private func compactButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11 * uiScale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 26 * uiScale, height: 26 * uiScale)
        }
        .buttonStyle(.plain)
    }
}
