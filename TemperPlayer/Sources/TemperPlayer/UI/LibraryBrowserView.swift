import SwiftUI

struct LibraryBrowserView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    var searchText = ""
    @State private var expandedArtists: Set<String> = []
    @State private var expandedAlbums: Set<String> = []

    private struct AlbumGroup: Identifiable {
        let id: String
        let name: String
        let tracks: [Track]
    }
    private struct ArtistGroup: Identifiable {
        let id: String
        let albums: [AlbumGroup]
        var tracks: [Track] { albums.flatMap(\.tracks) }
    }

    private var artists: [ArtistGroup] {
        let filtered = LibraryQuery.filter(library.tracks, search: searchText)
        let grouped = Dictionary(grouping: filtered) { $0.albumArtist ?? $0.artist ?? "Unknown Artist" }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { artist in
            let albums = Dictionary(grouping: grouped[artist] ?? []) { $0.album ?? "Unknown Album" }
            return ArtistGroup(id: artist, albums: albums.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { album in
                AlbumGroup(id: "\(artist.count):\(artist)\(album)", name: album,
                           tracks: LibraryQuery.sorted(albums[album] ?? [], by: .album))
            })
        }
    }

    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var visibleTracks: [Track] {
        artists.filter { searching || expandedArtists.contains($0.id) }.flatMap { artist in
            artist.albums.filter { searching || expandedAlbums.contains($0.id) }.flatMap(\.tracks)
        }
    }

    var body: some View {
        Group {
            if artists.isEmpty {
                LibraryEmptyState(isSearching: !library.tracks.isEmpty)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8 * uiScale) {
                        ForEach(artists) { artist in
                            DisclosureGroup(isExpanded: expansion(artist.id, in: $expandedArtists)) {
                                ForEach(artist.albums) { album in
                                    DisclosureGroup(isExpanded: expansion(album.id, in: $expandedAlbums)) {
                                        ForEach(album.tracks) { track in albumRow(track, album: album) }
                                    } label: {
                                        HStack {
                                            Text(album.name).lineLimit(1)
                                            Spacer()
                                            Text("\(album.tracks.count)").foregroundStyle(.secondary)
                                            Menu {
                                                TrackActionsMenu(tracks: album.tracks, context: album.tracks, title: album.name)
                                            } label: { Image(systemName: "ellipsis") }
                                            .menuStyle(.borderlessButton).fixedSize()
                                            .accessibilityLabel("Actions for \(album.name)")
                                        }
                                    }
                                    .padding(.vertical, 4)
                                }
                            } label: {
                                HStack {
                                    Text(artist.id).fontWeight(.semibold)
                                    Spacer()
                                    Text("\(artist.tracks.count)").foregroundStyle(.secondary)
                                    Menu {
                                        TrackActionsMenu(tracks: artist.tracks, context: artist.tracks, title: artist.id)
                                    } label: { Image(systemName: "ellipsis") }
                                    .menuStyle(.borderlessButton).fixedSize()
                                    .accessibilityLabel("Actions for \(artist.id)")
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(12 * uiScale)
                }
            }
        }
        .font(.system(size: 11 * uiScale, design: .monospaced))
        .onAppear { playerState.setVisibleTracks(visibleTracks) }
        .onChange(of: visibleTracks.map(\.id)) { _, _ in playerState.setVisibleTracks(visibleTracks) }
    }

    private func expansion(_ id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(get: { searching || set.wrappedValue.contains(id) }, set: { expanded in
            if expanded { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }

    private func albumRow(_ track: Track, album: AlbumGroup) -> some View {
        HStack(spacing: 10) {
            Text(track.trackNo.map(String.init) ?? "–").foregroundStyle(.secondary).frame(width: 28)
            Text(track.displayTitle).lineLimit(1)
            Spacer()
            Text(track.formattedDuration).foregroundStyle(.secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(playerState.selectedTrackIds.contains(track.id) ? Color.white.opacity(0.10) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { playback.play(track: track, context: album.tracks, title: album.name) }
        .onTapGesture {
            playerState.selectedTrackId = track.id
            playerState.selectedTrackIds = [track.id]
        }
        .contextMenu { TrackActionsMenu(tracks: [track], context: album.tracks, title: album.name) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Play") { playback.play(track: track, context: album.tracks, title: album.name) }
    }
}
