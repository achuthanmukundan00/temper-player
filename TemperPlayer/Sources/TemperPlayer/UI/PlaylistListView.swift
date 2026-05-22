import SwiftUI

struct PlaylistListView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @Environment(\.uiScale) var uiScale
    @Binding var searchText: String
    @State private var selectedPlaylistId: String?
    @State private var showNewPlaylist = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(library.playlists) { playlist in
                        HStack(spacing: 6 * uiScale) {
                            Text("#")
                                .foregroundColor(Color(white: 0.3))
                                .frame(width: 12 * uiScale)

                            Text(playlist.name)
                                .foregroundColor(selectedPlaylistId == playlist.id ? .white : Color(white: 0.7))

                            Spacer()

                            Text("\(playlist.tracks.count)")
                                .font(.system(size: 9 * uiScale, design: .monospaced))
                                .foregroundColor(Color(white: 0.35))
                        }
                        .padding(.vertical, 3 * uiScale)
                        .padding(.horizontal, 8 * uiScale)
                        .background(selectedPlaylistId == playlist.id ? Color.white.opacity(0.04) : Color.clear)
                        .onTapGesture {
                            selectedPlaylistId = selectedPlaylistId == playlist.id ? nil : playlist.id
                        }
                        .contextMenu {
                            Button("Delete Playlist") {
                                library.deletePlaylist(id: playlist.id)
                                if selectedPlaylistId == playlist.id { selectedPlaylistId = nil }
                            }
                        }
                    }
                }
                .padding(4 * uiScale)

                if let pid = selectedPlaylistId {
                    let tracks = library.tracksForPlaylist(pid)
                    Color(white: 0.08).frame(height: 1).padding(.horizontal, 8 * uiScale)

                    ForEach(tracks) { track in
                        HStack(spacing: 6 * uiScale) {
                            Text("\u{251C}\u{2500}")
                                .foregroundColor(Color(white: 0.4))
                                .frame(width: 14 * uiScale, alignment: .leading)

                            Text(track.path.components(separatedBy: "/").last ?? "?")
                                .foregroundColor(Color(white: 0.7))
                                .lineLimit(1)

                            Spacer()

                            Text(formatDuration(track.duration))
                                .foregroundColor(Color(white: 0.35))
                                .font(.system(size: 9 * uiScale, design: .monospaced))
                        }
                        .padding(.vertical, 2 * uiScale)
                        .padding(.horizontal, 8 * uiScale)
                        .onTapGesture(count: 2) {
                            playTrack(track)
                        }
                        .contextMenu {
                            Button("Remove from Playlist") {
                                library.removeTrackFromPlaylist(trackId: track.id, playlistId: pid)
                            }
                        }
                    }
                }
            }
            .font(.system(size: 10 * uiScale, design: .monospaced))

            if showNewPlaylist {
                HStack(spacing: 6 * uiScale) {
                    TextField("playlist name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10 * uiScale, design: .monospaced))
                        .foregroundColor(.white)
                    Button("OK") {
                        let trimmed = newName.trimmingCharacters(in: .whitespaces)
                        if !trimmed.isEmpty {
                            _ = library.createPlaylist(name: trimmed)
                        }
                        newName = ""
                        showNewPlaylist = false
                    }
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .buttonStyle(.plain)
                    .foregroundColor(Color(red: 0.4, green: 0.8, blue: 0.4))
                }
                .padding(.horizontal, 8 * uiScale)
                .padding(.vertical, 4 * uiScale)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Button("+") {
                showNewPlaylist = true
                newName = ""
            }
            .font(.system(size: 12 * uiScale, design: .monospaced))
            .buttonStyle(.plain)
            .foregroundColor(Color(white: 0.5))
            .padding(8 * uiScale)
        }
    }

    private func playTrack(_ track: Track) {
        playerState.currentTrack = track
        playerState.duration = track.duration
        playerState.currentTime = 0
        audioManager.play(track: track.path)
        playerState.isPlaying = true
    }

    private func formatDuration(_ d: Double) -> String {
        let m = Int(d) / 60; let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }
}
