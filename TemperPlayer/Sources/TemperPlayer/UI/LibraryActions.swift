import SwiftUI

/// Shared presentation state so context menus and keyboard commands use the same safeguards.
@MainActor
final class LibraryActions: ObservableObject {
    @Published var removalTracks: [Track] = []
    @Published var isConfirmingRemoval = false
    @Published var playlistTracks: [Track] = []
    @Published var isCreatingPlaylist = false
    @Published var showingManager = false
    @Published var showingQueue = false

    var isPresenting: Bool {
        isConfirmingRemoval || isCreatingPlaylist || showingManager || showingQueue
    }

    private var canPresent: Bool {
        !isPresenting && NSApp?.modalWindow == nil && NSApp?.keyWindow?.attachedSheet == nil
    }

    func presentManager() {
        guard canPresent else { return }
        showingManager = true
    }

    func presentQueue() {
        guard canPresent else { return }
        showingQueue = true
    }

    func requestRemoval(_ tracks: [Track]) {
        guard canPresent, !tracks.isEmpty else { return }
        removalTracks = tracks
        isConfirmingRemoval = true
    }

    func requestPlaylist(_ tracks: [Track]) {
        guard canPresent else { return }
        playlistTracks = tracks
        isCreatingPlaylist = true
    }
}

struct TrackActionsMenu: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var actions: LibraryActions
    let tracks: [Track]
    let context: [Track]
    let title: String

    var body: some View {
        Button(tracks.count > 1 ? "Play Selection" : "Play") {
            if let first = tracks.first {
                playback.play(track: first, context: tracks.count > 1 ? tracks : context, title: title)
            }
        }
        .disabled(tracks.isEmpty)
        Button("Play Next") {
            for track in tracks.reversed() { playback.enqueueNext(track) }
        }
        .disabled(tracks.isEmpty)
        Button("Add to Queue") { playback.enqueue(tracks) }
            .disabled(tracks.isEmpty)
        Divider()
        Menu("Add to Playlist") {
            Button("New Playlist…") { actions.requestPlaylist(tracks) }
            if !library.playlists.isEmpty { Divider() }
            ForEach(library.playlists) { playlist in
                Button(playlist.name) {
                    library.addTracksToPlaylist(trackIds: tracks.map(\.id), playlistId: playlist.id)
                }
            }
        }
        .disabled(tracks.isEmpty)
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting(tracks.map { URL(fileURLWithPath: $0.path) })
        }
        .disabled(tracks.isEmpty)
        Divider()
        Button("Remove from Library…", role: .destructive) { actions.requestRemoval(tracks) }
            .disabled(tracks.isEmpty)
    }
}

struct NewPlaylistSheet: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var actions: LibraryActions
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Playlist").font(.headline)
            Text("Add \(actions.playlistTracks.count) selected tracks to a new playlist.")
                .foregroundStyle(.secondary)
            TextField("Playlist name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(create)
            if let error = library.lastError { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let playlist = library.createPlaylist(name: trimmed, trackIds: actions.playlistTracks.map(\.id))
        guard library.playlists.contains(where: { $0.id == playlist.id }) else { return }
        dismiss()
    }
}

struct LibraryEmptyState: View {
    let isSearching: Bool
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: isSearching ? "magnifyingglass" : "music.note.house")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(isSearching ? "No matching tracks" : "Your music, in one place")
                .font(.headline)
            Text(isSearching ? "Try a different title, artist, album, or file name." : "Import files or folders, or drop them into this window. Your originals stay where they are.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 350)
            if !isSearching {
                Button("Import Music…") { ImportService.shared.presentImportPanel() }
                Text("FLAC · WAV · MP3 · M4A · AAC · MP4")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
