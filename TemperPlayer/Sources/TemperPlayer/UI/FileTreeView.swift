import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @Binding var hoveredTrackId: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(library.tracks) { track in
                    FileTreeRow(
                        track: track,
                        isPlaying: playerState.currentTrack?.id == track.id,
                        isHovered: hoveredTrackId == track.id
                    )
                    .onHover { hovering in
                        hoveredTrackId = hovering ? track.id : nil
                    }
                    .onTapGesture(count: 2) {
                        playTrack(track)
                    }
                }
            }
            .padding(4)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    private func playTrack(_ track: Track) {
        playerState.currentTrack = track
        playerState.duration = track.duration
        playerState.currentTime = 0
        audioManager.play(track: track.path)
        playerState.isPlaying = true
    }
}

struct FileTreeRow: View {
    let track: Track
    let isPlaying: Bool
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isPlaying {
                Text("\u{25B6}").foregroundColor(.white).frame(width: 12)
            } else {
                Text(docIcon).foregroundColor(Color(white: 0.3)).frame(width: 12)
            }

            Text("\u{251C}\u{2500}")
                .foregroundColor(Color(white: 0.4))
                .frame(width: 14, alignment: .leading)

            Text(track.path.components(separatedBy: "/").last ?? "?")
                .foregroundColor(isPlaying ? .white : Color(white: 0.7))

            Spacer()

            let m = Int(track.duration) / 60
            let s = Int(track.duration) % 60
            Text(String(format: "%d:%02d", m, s))
                .foregroundColor(Color(white: 0.35))
                .font(.system(size: 9, design: .monospaced))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(isPlaying ? Color.white.opacity(0.04) : (isHovered ? Color.white.opacity(0.02) : Color.clear))
    }

    private var docIcon: String {
        switch track.format {
        case "flac": return "\u{2669}"
        case "wav": return "\u{266A}"
        default: return "\u{25CC}"
        }
    }
}
