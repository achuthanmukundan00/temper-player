import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playerState: PlayerState

    var body: some View {
        HStack(spacing: 8) {
            Text(">").foregroundColor(Color(white: 0.5))

            Text(playerState.displayPath)
                .foregroundColor(Color(white: 0.7))
                .lineLimit(1)

            Spacer()

            HStack(spacing: 6) {
                transportButton("\u{2508}\u{25C0}") { previousTrack() }
                transportButton("\u{25C0}") { audioManager.seek(to: max(0, playerState.currentTime - 5)) }
                playPauseButton
                transportButton("\u{25B6}") { audioManager.seek(to: min(playerState.duration, playerState.currentTime + 5)) }
                transportButton("\u{25B6}\u{2508}") { nextTrack() }
            }
            .foregroundColor(Color(white: 0.35))

            Text("\u{2502}").foregroundColor(Color(white: 0.12))

            Text("\(playerState.timeString) / \(playerState.durationString)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.35))
                .fontVariant(.tabularFigures)

            Text("\u{2502}").foregroundColor(Color(white: 0.12))

            Text("vol:\(Int(playerState.volume * 100))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(Color(white: 0.35))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color(white: 0.06))
                    Rectangle().fill(Color(white: 0.35))
                        .frame(width: geo.size.width * CGFloat(playerState.volume))
                }
            }
            .frame(width: 28, height: 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Color.black)
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1).frame(maxHeight: .infinity, alignment: .top))
    }

    private func transportButton(_ label: String, action: @escaping () -> Void) -> some View {
        Text(label).font(.system(size: 8, design: .monospaced))
            .foregroundColor(Color(white: 0.35)).onTapGesture { action() }
    }

    private var playPauseButton: some View {
        Text(playerState.isPlaying ? "\u{25A0}" : "\u{25B6}")
            .font(.system(size: 9, design: .monospaced))
            .foregroundColor(.white)
            .frame(width: 16, height: 16)
            .overlay(Circle().stroke(Color(white: 0.2), lineWidth: 1))
            .onTapGesture { togglePlay() }
    }

    private func togglePlay() {
        if playerState.isPlaying {
            audioManager.pause()
            playerState.isPlaying = false
        } else if let track = playerState.currentTrack {
            audioManager.play(track: track.path)
            playerState.isPlaying = true
        }
    }

    private func previousTrack() {
        guard !playerState.queue.isEmpty, let current = playerState.currentTrack,
              let idx = playerState.queue.firstIndex(of: current) else {
            audioManager.seek(to: 0); return
        }
        let t = playerState.queue[max(0, idx - 1)]
        playerState.currentTrack = t
        audioManager.play(track: t.path); playerState.isPlaying = true
    }

    private func nextTrack() {
        guard !playerState.queue.isEmpty, let current = playerState.currentTrack,
              let idx = playerState.queue.firstIndex(of: current),
              idx + 1 < playerState.queue.count else { return }
        let t = playerState.queue[idx + 1]
        playerState.currentTrack = t
        audioManager.play(track: t.path); playerState.isPlaying = true
    }
}
