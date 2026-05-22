import SwiftUI

struct LibraryBrowserView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var audioManager: AudioManager
    @Environment(\.uiScale) var uiScale
    @State private var selectedArtist: String?
    @State private var selectedAlbum: String?

    private var artists: [(name: String, albums: [(name: String, tracks: [Track])])] {
        let grouped = Dictionary(grouping: library.tracks) { $0.artist ?? "Unknown Artist" }
        return grouped.keys.sorted().map { artist in
            let albumGroup = Dictionary(grouping: grouped[artist]!) { $0.album ?? "Unknown Album" }
            let albums = albumGroup.keys.sorted().map { album in
                (name: album, tracks: albumGroup[album]!.sorted { ($0.trackNo ?? 999) < ($1.trackNo ?? 999) })
            }
            return (name: artist, albums: albums)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(artists, id: \.name) { artist in
                    let isExpanded = selectedArtist == artist.name
                    HStack(spacing: 6 * uiScale) {
                        Text(isExpanded ? "\u{25BC}" : "\u{25B6}")
                            .font(.system(size: 8 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                            .frame(width: 10 * uiScale)

                        Text(artist.name)
                            .foregroundColor(.white)

                        Spacer()

                        Text("\(artist.albums.reduce(0) { $0 + $1.tracks.count })")
                            .font(.system(size: 9 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .padding(.vertical, 3 * uiScale)
                    .padding(.horizontal, 8 * uiScale)
                    .background(isExpanded ? Color.white.opacity(0.03) : Color.clear)
                    .onTapGesture {
                        withAnimation(.none) {
                            selectedArtist = isExpanded ? nil : artist.name
                            selectedAlbum = nil
                        }
                    }

                    if isExpanded {
                        ForEach(artist.albums, id: \.name) { album in
                            let albumExpanded = selectedAlbum == album.name
                            HStack(spacing: 6 * uiScale) {
                                Text("\u{2502}  ")
                                    .foregroundColor(Color(white: 0.15))
                                    .frame(width: 14 * uiScale)

                                Text(albumExpanded ? "\u{25BC}" : "\u{25B6}")
                                    .font(.system(size: 7 * uiScale, design: .monospaced))
                                    .foregroundColor(Color(white: 0.25))
                                    .frame(width: 8 * uiScale)

                                Text(album.name)
                                    .foregroundColor(Color(white: 0.6))

                                Spacer()

                                Text("\(album.tracks.count)")
                                    .font(.system(size: 8 * uiScale, design: .monospaced))
                                    .foregroundColor(Color(white: 0.2))
                            }
                            .padding(.vertical, 2 * uiScale)
                            .padding(.leading, 16 * uiScale)
                            .padding(.trailing, 8 * uiScale)
                            .background(albumExpanded ? Color.white.opacity(0.02) : Color.clear)
                            .onTapGesture {
                                withAnimation(.none) {
                                    selectedAlbum = albumExpanded ? nil : album.name
                                }
                            }

                            if albumExpanded {
                                ForEach(album.tracks) { track in
                                    HStack(spacing: 6 * uiScale) {
                                        Text("\u{2502}     \u{251C}\u{2500}")
                                            .foregroundColor(Color(white: 0.15))
                                            .frame(width: 28 * uiScale, alignment: .leading)

                                        if let tn = track.trackNo {
                                            Text("\(tn).")
                                                .font(.system(size: 9 * uiScale, design: .monospaced))
                                                .foregroundColor(Color(white: 0.3))
                                                .frame(width: 24 * uiScale, alignment: .trailing)
                                        }

                                        Text(track.title ?? track.path.components(separatedBy: "/").last ?? "?")
                                            .foregroundColor(playerState.currentTrack?.id == track.id ? .white : Color(white: 0.7))
                                            .lineLimit(1)

                                        Spacer()

                                        let m = Int(track.duration) / 60
                                        let s = Int(track.duration) % 60
                                        Text(String(format: "%d:%02d", m, s))
                                            .font(.system(size: 9 * uiScale, design: .monospaced))
                                            .foregroundColor(Color(white: 0.35))
                                    }
                                    .padding(.vertical, 2 * uiScale)
                                    .padding(.leading, 32 * uiScale)
                                    .padding(.trailing, 8 * uiScale)
                                    .onTapGesture(count: 2) {
                                        playTrack(track)
                                    }
                                }
                            }
                        }
                    }

                    Color(white: 0.04).frame(height: 1)
                }
            }
            .padding(4 * uiScale)
        }
        .font(.system(size: 10 * uiScale, design: .monospaced))
    }

    private func playTrack(_ track: Track) {
        playerState.currentTrack = track
        playerState.duration = track.duration
        playerState.currentTime = 0
        audioManager.play(track: track.path)
        playerState.isPlaying = true
    }
}
