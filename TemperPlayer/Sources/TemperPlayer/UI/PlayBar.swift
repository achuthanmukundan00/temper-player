import SwiftUI

struct PlayBar: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    private var analyzer: RealtimeAnalyzer { audioManager.analyzer }

    var body: some View {
        HStack(spacing: 6 * uiScale) {
            Text(playerState.timeString)
                .font(.system(size: 9 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.4))
                .frame(width: 44 * uiScale, alignment: .leading)

            GeometryReader { geo in
                let progress = playerState.duration > 0 ? CGFloat(playerState.currentTime / playerState.duration) : 0
                let fillW = geo.size.width * progress

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(white: 0.1))
                        .frame(height: 4 * uiScale)

                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color(white: 0.7))
                        .frame(width: fillW, height: 4 * uiScale)

                    Circle()
                        .fill(.white)
                        .frame(width: 7 * uiScale, height: 7 * uiScale)
                        .offset(x: fillW - 3.5 * uiScale)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            playerState.currentTime = p * playerState.duration
                        }
                        .onEnded { v in
                            let p = max(0, min(1, v.location.x / geo.size.width))
                            playback.seek(to: p * playerState.duration)
                        }
                )
            }
            .frame(height: 20 * uiScale)

            Text(playerState.durationString)
                .font(.system(size: 9 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.25))
                .frame(width: 44 * uiScale, alignment: .trailing)

            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "P:%.1f", analyzer.peak))
                    .font(.system(size: 7 * uiScale, design: .monospaced))
                    .foregroundColor(analyzer.peak > 0.9 ? .red : Color(white: 0.3))
                Text(String(format: "R:%.1f", analyzer.rms))
                    .font(.system(size: 7 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.2))
            }
            .frame(width: 44 * uiScale)
        }
        .padding(.horizontal, 16 * uiScale)
        .frame(height: 24 * uiScale)
    }
}
