import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Text(playerState.displayPath)
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6 * uiScale) {
                transportButton(systemName: "backward.fill") { playback.previous() }
                transportButton(systemName: "gobackward.5") { playback.seek(by: -5) }
                playPauseButton
                transportButton(systemName: "goforward.5") { playback.seek(by: 5) }
                transportButton(systemName: "forward.fill") { playback.next() }
            }

            Text("\(playerState.timeString) / \(playerState.durationString)")
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.secondary)

            HStack(spacing: 4 * uiScale) {
                Image(systemName: "speaker.wave.1.fill")
                    .font(.system(size: 8 * uiScale))
                    .foregroundStyle(.tertiary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary)
                            .frame(width: geo.size.width * CGFloat(playerState.volume))
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let vol = Float(min(1, max(0, v.location.x / geo.size.width)))
                        playback.setVolume(vol)
                    })
                }
                .frame(width: 32 * uiScale, height: 4 * uiScale)
            }
        }
        .padding(.horizontal, 14 * uiScale)
        .frame(height: 34 * uiScale)
        .background(Color.black)
        .overlay(
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8 * uiScale, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private var playPauseButton: some View {
        Button(action: { playback.togglePlayPause() }) {
            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 9 * uiScale, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 16 * uiScale, height: 16 * uiScale)
                .overlay(Circle().stroke(.tertiary, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
