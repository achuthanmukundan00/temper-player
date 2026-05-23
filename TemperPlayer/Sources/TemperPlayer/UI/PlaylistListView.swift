import SwiftUI

struct PlaylistListView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    @Binding var searchText: String
    @State private var selectedPlaylistId: String?
    @State private var showNewPlaylist = false
    @State private var newName = ""
    @State private var editingName = ""

    private var selectedPlaylist: Playlist? {
        guard let selectedPlaylistId else { return library.playlists.first }
        return library.playlists.first { $0.id == selectedPlaylistId } ?? library.playlists.first
    }

    private var selectedTracks: [Track] {
        guard let playlist = selectedPlaylist else { return [] }
        let tracks = library.tracksForPlaylist(playlist.id)
        guard !searchText.isEmpty else { return tracks }
        let q = searchText.lowercased()
        return tracks.filter {
            ($0.title?.lowercased().contains(q) ?? false) ||
            ($0.artist?.lowercased().contains(q) ?? false) ||
            ($0.album?.lowercased().contains(q) ?? false) ||
            $0.path.lowercased().contains(q)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            playlistSidebar
                .frame(width: 170 * uiScale)

            Rectangle()
                .fill(Color(white: 0.06))
                .frame(width: 1)

            playlistDetail
        }
        .font(.system(size: 10 * uiScale, design: .monospaced))
        .onAppear {
            if selectedPlaylistId == nil {
                selectedPlaylistId = library.playlists.first?.id
            }
            playerState.setVisibleTracks(selectedTracks)
        }
        .onChange(of: library.playlists.map(\.id)) { _, ids in
            if selectedPlaylistId == nil || !ids.contains(selectedPlaylistId ?? "") {
                selectedPlaylistId = ids.first
            }
            playerState.setVisibleTracks(selectedTracks)
        }
        .onChange(of: selectedPlaylistId) { _, _ in
            playerState.setVisibleTracks(selectedTracks)
        }
        .onChange(of: selectedTracks.map(\.id)) { _, _ in
            playerState.setVisibleTracks(selectedTracks)
        }
    }

    private var playlistSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SETS")
                    .font(.system(size: 8 * uiScale, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(white: 0.32))
                    .tracking(1.2)
                Spacer()
                Button("+") {
                    showNewPlaylist = true
                    newName = ""
                }
                .buttonStyle(.plain)
                .foregroundColor(Color(white: 0.55))
            }
            .padding(.horizontal, 10 * uiScale)
            .padding(.vertical, 6 * uiScale)
            .background(Color(white: 0.025))
            .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)

            if showNewPlaylist {
                HStack(spacing: 6 * uiScale) {
                    TextField("name", text: $newName)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .onSubmit(createPlaylist)

                    Button("OK", action: createPlaylist)
                        .buttonStyle(.plain)
                        .foregroundColor(Color(red: 0.45, green: 0.8, blue: 0.52))
                }
                .padding(.horizontal, 10 * uiScale)
                .padding(.vertical, 7 * uiScale)
                .background(Color(white: 0.045))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(library.playlists.enumerated()), id: \.element.id) { index, playlist in
                        playlistRow(playlist, index: index)
                    }
                }
                .padding(.vertical, 4 * uiScale)
            }
        }
        .background(Color.black)
    }

    private var playlistDetail: some View {
        VStack(spacing: 0) {
            if let playlist = selectedPlaylist {
                detailHeader(for: playlist)
                PlaylistTrackHeader(uiScale: uiScale)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(selectedTracks.enumerated()), id: \.element.id) { index, track in
                            playlistTrackRow(track, index: index, playlist: playlist)
                        }
                    }
                    .padding(.vertical, 4 * uiScale)
                }
            } else {
                Spacer()
                Text("No playlists")
                    .foregroundColor(Color(white: 0.32))
                Spacer()
            }
        }
        .background(Color.black)
    }

    private func playlistRow(_ playlist: Playlist, index: Int) -> some View {
        let isSelected = selectedPlaylist?.id == playlist.id
        return HStack(spacing: 8 * uiScale) {
            Text("#")
                .foregroundColor(isSelected ? .white : Color(white: 0.28))
                .frame(width: 12 * uiScale)
            VStack(alignment: .leading, spacing: 1 * uiScale) {
                Text(playlist.name)
                    .foregroundColor(isSelected ? .white : Color(white: 0.72))
                    .lineLimit(1)
                Text("\(playlist.tracks.count) tracks")
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.28))
            }
            Spacer()
        }
        .padding(.horizontal, 10 * uiScale)
        .padding(.vertical, 7 * uiScale)
        .background(isSelected ? Color.white.opacity(0.07) : (index.isMultiple(of: 2) ? Color(white: 0.032) : Color(white: 0.045)))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlaylistId = playlist.id
            editingName = playlist.name
        }
        .contextMenu {
            Button("Play") { playPlaylist(playlist) }
            Button("Add to Queue") { playback.enqueue(library.tracksForPlaylist(playlist.id)) }
            Divider()
            Button("Delete Playlist") { deletePlaylist(playlist) }
        }
    }

    private func detailHeader(for playlist: Playlist) -> some View {
        let tracks = library.tracksForPlaylist(playlist.id)
        return HStack(spacing: 8 * uiScale) {
            TextField("playlist", text: Binding(
                get: { editingName.isEmpty ? playlist.name : editingName },
                set: { editingName = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13 * uiScale, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .onSubmit {
                library.renamePlaylist(id: playlist.id, name: editingName)
            }
            .onAppear { editingName = playlist.name }

            Text("\(tracks.count) / \(formatDuration(totalDuration(tracks)))")
                .foregroundColor(Color(white: 0.35))

            Spacer()

            Button("PLAY") { playPlaylist(playlist) }
                .buttonStyle(.plain)
                .foregroundColor(.white)

            Button("QUEUE") { playback.enqueue(tracks) }
                .buttonStyle(.plain)
                .foregroundColor(Color(white: 0.55))

            Button("CLEAR") { library.clearPlaylist(id: playlist.id) }
                .buttonStyle(.plain)
                .font(.system(size: 8 * uiScale, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .padding(.horizontal, 6 * uiScale)
                .padding(.vertical, 3 * uiScale)
                .background(Color.red.opacity(0.85))
                .cornerRadius(3)
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 8 * uiScale)
        .background(Color(white: 0.025))
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)
    }

    private func playlistTrackRow(_ track: Track, index: Int, playlist: Playlist) -> some View {
        let isPlaying = playerState.currentTrack?.id == track.id
        let isSelected = playerState.selectedTrackId == track.id
        return HStack(spacing: 10 * uiScale) {
            Text(isPlaying ? "\u{25B6}" : String(format: "%02d", index + 1))
                .foregroundColor(isPlaying ? .white : Color(white: 0.34))
                .frame(width: 28 * uiScale, alignment: .trailing)

            Text(track.title ?? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent)
                .foregroundColor(isPlaying ? .white : Color(white: 0.76))
                .lineLimit(1)
                .frame(minWidth: 180 * uiScale, maxWidth: .infinity, alignment: .leading)

            Text(track.artist ?? "Unknown Artist")
                .foregroundColor(Color(white: 0.5))
                .lineLimit(1)
                .frame(width: 130 * uiScale, alignment: .leading)

            Text(formatDuration(track.duration))
                .foregroundColor(Color(white: 0.34))
                .frame(width: 48 * uiScale, alignment: .trailing)
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 6 * uiScale)
        .background(rowBackground(isPlaying: isPlaying, isSelected: isSelected, index: index))
        .contentShape(Rectangle())
        .onTapGesture {
            playerState.selectedTrackId = track.id
        }
        .onTapGesture(count: 2) {
            playback.play(track: track, context: library.tracksForPlaylist(playlist.id), title: playlist.name)
        }
        .contextMenu {
            Button("Play") {
                playback.play(track: track, context: library.tracksForPlaylist(playlist.id), title: playlist.name)
            }
            Button("Play Next") { playback.enqueueNext(track) }
            Button("Add to Queue") { playback.enqueue(track) }
            Divider()
            Button("Move Up") { library.moveTrackInPlaylist(playlistId: playlist.id, trackId: track.id, by: -1) }
            Button("Move Down") { library.moveTrackInPlaylist(playlistId: playlist.id, trackId: track.id, by: 1) }
            Button("Remove from Playlist") {
                library.removeTrackFromPlaylist(trackId: track.id, playlistId: playlist.id)
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.selectFile(track.path, inFileViewerRootedAtPath: "")
            }
        }
    }

    private func rowBackground(isPlaying: Bool, isSelected: Bool, index: Int) -> Color {
        if isPlaying { return Color(red: 0.11, green: 0.13, blue: 0.12) }
        if isSelected { return Color(red: 0.13, green: 0.13, blue: 0.18) }
        return index.isMultiple(of: 2) ? Color(white: 0.035) : Color(white: 0.048)
    }

    private func createPlaylist() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            showNewPlaylist = false
            return
        }
        let playlist = library.createPlaylist(name: trimmed)
        selectedPlaylistId = playlist.id
        editingName = playlist.name
        newName = ""
        showNewPlaylist = false
    }

    private func deletePlaylist(_ playlist: Playlist) {
        library.deletePlaylist(id: playlist.id)
        if selectedPlaylistId == playlist.id {
            selectedPlaylistId = library.playlists.first?.id
        }
    }

    private func playPlaylist(_ playlist: Playlist) {
        let tracks = library.tracksForPlaylist(playlist.id)
        guard let first = tracks.first else { return }
        playback.play(track: first, context: tracks, title: playlist.name)
    }

    private func totalDuration(_ tracks: [Track]) -> Double {
        tracks.reduce(0) { $0 + max(0, $1.duration) }
    }

    private func formatDuration(_ d: Double) -> String {
        guard d.isFinite, d > 0 else { return "--:--" }
        let total = Int(d)
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct PlaylistTrackHeader: View {
    let uiScale: CGFloat

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Text("#").frame(width: 28 * uiScale, alignment: .trailing)
            Text("TITLE").frame(minWidth: 180 * uiScale, maxWidth: .infinity, alignment: .leading)
            Text("ARTIST").frame(width: 130 * uiScale, alignment: .leading)
            Text("TIME").frame(width: 48 * uiScale, alignment: .trailing)
        }
        .font(.system(size: 8 * uiScale, weight: .medium, design: .monospaced))
        .foregroundColor(Color(white: 0.32))
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 5 * uiScale)
        .background(Color(white: 0.025))
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)
    }
}
