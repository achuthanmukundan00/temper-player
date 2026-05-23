import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale

    var body: some View {
        HStack(spacing: 8 * uiScale) {
            Text(">").foregroundColor(Color(white: 0.5))

            Text(playerState.displayPath)
                .foregroundColor(Color(white: 0.7))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6 * uiScale) {
                transportButton("\u{2508}\u{25C0}") { playback.previous() }
                transportButton("\u{25C0}") { playback.seek(by: -5) }
                playPauseButton
                transportButton("\u{25B6}") { playback.seek(by: 5) }
                transportButton("\u{25B6}\u{2508}") { playback.next() }
            }
            .foregroundColor(Color(white: 0.35))

            Text("\u{2502}").foregroundColor(Color(white: 0.12))

            Text("\(playerState.timeString) / \(playerState.durationString)")
                .font(.system(size: 9 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.35))

            Text("\u{2502}").foregroundColor(Color(white: 0.12))

            Text("vol:\(Int(playerState.volume * 100))")
                .font(.system(size: 9 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.35))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.06))
                    Rectangle().fill(Color(white: 0.35))
                        .frame(width: geo.size.width * CGFloat(playerState.volume))
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    let vol = Float(min(1, max(0, v.location.x / geo.size.width)))
                    playback.setVolume(vol)
                })
            }
            .frame(width: 28 * uiScale, height: 4 * uiScale)

            Text("\(Int(uiScale * 100))%")
                .font(.system(size: 7 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.25))
        }
        .padding(.horizontal, 12 * uiScale)
        .frame(height: 34 * uiScale)
        .background(Color.black)
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .top))
    }

    private func transportButton(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 8 * uiScale, design: .monospaced))
            .foregroundColor(Color(white: 0.35)).onTapGesture { action() }
    }

    private var playPauseButton: some View {
        Text(playerState.isPlaying ? "\u{25A0}" : "\u{25B6}")
            .font(.system(size: 9 * uiScale, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 16 * uiScale, height: 16 * uiScale)
            .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 1))
            .onTapGesture { togglePlay() }
    }

    private func togglePlay() {
        playback.togglePlayPause()
    }
}
