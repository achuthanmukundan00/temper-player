import SwiftUI

struct SuperCompactPlayerView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var library: Database
    @Environment(\.uiScale) var uiScale
    @ObservedObject private var importService = ImportService.shared

    var body: some View {
        if let track = playerState.currentTrack {
            VStack(spacing: 0) {
                HStack(spacing: 8 * uiScale) {
                    artworkView(for: track)
                        .frame(width: 28 * uiScale, height: 28 * uiScale)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title ?? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent)
                            .font(.system(size: 10 * uiScale))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if let artist = track.artist {
                            Text(artist)
                                .font(.system(size: 8 * uiScale))
                                .foregroundColor(Color(white: 0.45))
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    HStack(spacing: 10 * uiScale) {
                        Button(action: { playback.previous() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 9 * uiScale, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 18 * uiScale, height: 18 * uiScale)
                        }
                        .buttonStyle(.plain)

                        Button(action: { playback.togglePlayPause() }) {
                            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 8 * uiScale, weight: .medium))
                                .foregroundColor(.white)
                                .frame(width: 20 * uiScale, height: 20 * uiScale)
                                .background(Circle().stroke(Color(white: 0.3), lineWidth: 1))
                        }
                        .buttonStyle(.plain)

                        Button(action: { playback.next() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 9 * uiScale, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 18 * uiScale, height: 18 * uiScale)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10 * uiScale)
                .padding(.vertical, 7 * uiScale)

                // Mini progress bar
                GeometryReader { geo in
                    let progress = playerState.duration > 0 ? CGFloat(playerState.currentTime / playerState.duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary).frame(height: 1.5)
                        Capsule()
                            .fill(.secondary)
                            .frame(width: max(2, geo.size.width * progress), height: 1.5)
                    }
                }
                .frame(height: 1.5)
            }
            .background(Color.black)
        } else {
            HStack {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Text("TemperPlayer")
                    .font(.system(size: 10))
                    .foregroundColor(Color(white: 0.25))
                Spacer()
                Text("Resize wider to browse")
                    .font(.system(size: 8))
                    .foregroundColor(Color(white: 0.15))
            }
            .padding(.horizontal, 12)
            .frame(height: 40 * uiScale)
            .background(Color.black)
        }
    }

    @ViewBuilder
    private func artworkView(for track: Track) -> some View {
        if let data = importService.artwork(for: track.id), let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 0.5))
        } else {
            RoundedRectangle(cornerRadius: 3)
                .fill(.quaternary.opacity(0.3))
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 8, weight: .light))
                        .foregroundStyle(.quaternary)
                )
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary, lineWidth: 0.5))
        }
    }
}
