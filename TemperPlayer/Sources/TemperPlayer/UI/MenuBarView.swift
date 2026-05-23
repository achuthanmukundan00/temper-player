import SwiftUI

struct MenuBarView: View {
    let playerState: PlayerState
    let audioManager: AudioManager
    let playback: PlaybackController
    let library: Database
    let importService: ImportService

    @State private var hoveredButton: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            if let track = playerState.currentTrack {
                // Artwork + track info row
                HStack(spacing: 10) {
                    artworkView(for: track)
                        .frame(width: 52, height: 52)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title ?? track.path.components(separatedBy: "/").last ?? "Unknown")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(track.artist ?? "Unknown Artist")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Text(formatInfo(track))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

                Divider()
                    .padding(.horizontal, 14)

                // Transport controls row
                HStack(spacing: 0) {
                    transportButton(
                        systemName: "backward.fill",
                        hint: "previousTrack"
                    ) {
                        playback.previous()
                    }

                    Spacer()

                    transportButton(
                        systemName: "gobackward.5",
                        hint: "seekBackward"
                    ) {
                        playback.seek(by: -5)
                    }

                    Spacer()

                    // Play/Pause - larger, prominent
                    playPauseButton

                    Spacer()

                    transportButton(
                        systemName: "goforward.5",
                        hint: "seekForward"
                    ) {
                        playback.seek(by: 5)
                    }

                    Spacer()

                    transportButton(
                        systemName: "forward.fill",
                        hint: "nextTrack"
                    ) {
                        playback.next()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                // Mini progress bar
                GeometryReader { geo in
                    let progress = playerState.duration > 0 ? CGFloat(playerState.currentTime / playerState.duration) : 0
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.quaternary)
                            .frame(height: 3)
                        Capsule()
                            .fill(.secondary)
                            .frame(width: max(4, geo.size.width * progress), height: 3)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

            } else {
                // Empty state
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 28))
                        .foregroundStyle(.quaternary)
                        .padding(.top, 20)

                    Text("TemperPlayer")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Text("Open the main window to play music")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(width: 320)
    }

    // MARK: - Artwork

    @ViewBuilder
    private func artworkView(for track: Track) -> some View {
        if let data = importService.artwork(for: track.id),
           let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 5)
                .fill(.quaternary.opacity(0.3))
                .frame(width: 52, height: 52)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(.quaternary)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Transport Buttons

    private func transportButton(
        systemName: String,
        hint: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(hoveredButton == hint ? .primary : .secondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredButton = hovering ? hint : nil
            }
        }
    }

    private var playPauseButton: some View {
        Button(action: { playback.togglePlayPause() }) {
            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(.quaternary.opacity(hoveredButton == "playPause" ? 0.6 : 0.3))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredButton = hovering ? "playPause" : nil
            }
        }
    }

    // MARK: - Helpers

    private func formatInfo(_ track: Track) -> String {
        var parts: [String] = [track.format.uppercased()]
        if track.sampleRate >= 1000 {
            parts.append("\(track.sampleRate / 1000).\(track.sampleRate % 1000 / 100)k")
        } else {
            parts.append("\(track.sampleRate)")
        }
        parts.append("\(track.bitDepth)bit")
        return parts.joined(separator: " · ")
    }
}
