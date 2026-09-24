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
    @State private var creationError: String?
    @State private var renamingPlaylistId: String?
    @State private var editingName = ""
    @State private var renameError: String?
    @State private var pendingConfirmation: PlaylistConfirmation?
    @State private var selectionAnchorId: String?
    @State private var statusMessage: String?
    @State private var actionError: String?
    @FocusState private var focusedNameField: NameField?
    @FocusState private var isTrackListFocused: Bool

    private enum NameField: Hashable {
        case newPlaylist, rename
    }

    private enum PlaylistConfirmation {
        case clear(Playlist), delete(Playlist)

        var playlist: Playlist {
            switch self {
            case .clear(let playlist), .delete(let playlist): return playlist
            }
        }

        var actionName: String {
            switch self {
            case .clear: return "Clear Playlist"
            case .delete: return "Delete Playlist"
            }
        }

        var message: String {
            switch self {
            case .clear:
                return "Remove all tracks from “\(playlist.name)”? The playlist stays, and its tracks remain in your library. No source files are deleted."
            case .delete:
                return "Delete “\(playlist.name)”? Only this playlist is deleted. Its tracks remain in your library and no source files are deleted."
            }
        }
    }

    private var selectedPlaylist: Playlist? {
        library.playlists.first { $0.id == selectedPlaylistId } ?? library.playlists.first
    }

    private var playlistTracks: [Track] {
        guard let playlist = selectedPlaylist else { return [] }
        return library.tracksForPlaylist(playlist.id)
    }

    private var searchQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredTracks: [Track] {
        LibraryQuery.filter(playlistTracks, search: searchText)
    }

    private var selectedPlaylistTracks: [Track] {
        filteredTracks.filter { playerState.selectedTrackIds.contains($0.id) }
    }

    var body: some View {
        HStack(spacing: 0) {
            playlistSidebar
                .frame(width: 170 * uiScale)

            Rectangle()
                .fill(Color(white: 0.06))
                .frame(width: 1)

            GeometryReader { geometry in
                playlistDetail(layout: FileTableLayout(width: geometry.size.width, uiScale: uiScale))
            }
        }
        .font(.system(size: 10 * uiScale, design: .monospaced))
        .onAppear {
            if selectedPlaylistId == nil {
                selectedPlaylistId = library.playlists.first?.id
            }
            synchronizeVisibleTracks()
        }
        .onChange(of: library.playlists.map(\.id)) { _, ids in
            if selectedPlaylistId == nil || !ids.contains(selectedPlaylistId ?? "") {
                selectedPlaylistId = ids.first
            }
        }
        .onChange(of: selectedPlaylist?.id) { _, id in
            if renamingPlaylistId != id { cancelRename() }
            isTrackListFocused = false
            synchronizeVisibleTracks(resetSelection: true)
        }
        .onChange(of: filteredTracks.map(\.id)) { _, _ in
            synchronizeVisibleTracks()
        }
        .onChange(of: playerState.selectedTrackId) { _, id in
            if !playerState.selectedTrackIds.contains(selectionAnchorId ?? "") {
                selectionAnchorId = id
            }
        }
        .alert(pendingConfirmation?.actionName ?? "Playlist", isPresented: Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        ), presenting: pendingConfirmation) { confirmation in
            Button("Cancel", role: .cancel) { pendingConfirmation = nil }
            Button(confirmation.actionName, role: .destructive) {
                performConfirmedAction(confirmation)
                pendingConfirmation = nil
            }
        } message: { confirmation in
            Text(confirmation.message)
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
                Button("+", action: beginCreatingPlaylist)
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.65))
                    .accessibilityLabel("Create playlist")
                    .help("Create playlist")
            }
            .padding(.horizontal, 10 * uiScale)
            .padding(.vertical, 6 * uiScale)
            .background(Color(white: 0.025))
            .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)

            if showNewPlaylist {
                VStack(alignment: .leading, spacing: 7 * uiScale) {
                    TextField("Playlist name", text: $newName)
                        .textFieldStyle(.plain)
                        .foregroundColor(.white)
                        .focused($focusedNameField, equals: .newPlaylist)
                        .onAppear { focusedNameField = .newPlaylist }
                        .onSubmit(createPlaylist)
                        .onExitCommand(perform: cancelCreatingPlaylist)

                    HStack {
                        Button("Cancel", action: cancelCreatingPlaylist)
                        Spacer()
                        Button("Create", action: createPlaylist)
                            .foregroundColor(Color(red: 0.45, green: 0.8, blue: 0.52))
                            .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.65))

                    if let creationError {
                        Text(creationError)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10 * uiScale)
                .padding(.vertical, 8 * uiScale)
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

    private func playlistDetail(layout: FileTableLayout) -> some View {
        VStack(spacing: 0) {
            if let message = actionError ?? statusMessage {
                HStack(alignment: .top, spacing: 8 * uiScale) {
                    Text(message)
                        .foregroundColor(actionError == nil ? Color(white: 0.65) : .red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Dismiss") {
                        actionError = nil
                        statusMessage = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.55))
                }
                .padding(10 * uiScale)
                .background(Color(white: 0.045))
            }

            if let playlist = selectedPlaylist {
                detailHeader(for: playlist, layout: layout)
                selectionBar(for: playlist, layout: layout)
                PlaylistTrackHeader(layout: layout)

                if playlistTracks.isEmpty {
                    emptyState(
                        title: "This playlist is empty",
                        message: "In Library, select tracks and choose Add to Playlist → \(playlist.name)."
                    )
                } else if filteredTracks.isEmpty {
                    VStack(spacing: 12 * uiScale) {
                        Text("No matching tracks")
                            .foregroundColor(Color(white: 0.75))
                        Text("No tracks in “\(playlist.name)” match “\(searchQuery)”.")
                            .foregroundColor(Color(white: 0.45))
                            .multilineTextAlignment(.center)
                        Button("Clear Search") { searchText = "" }
                            .buttonStyle(.plain)
                            .foregroundColor(.white)
                    }
                    .padding(24 * uiScale)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    trackList(for: playlist, layout: layout)
                }
            } else {
                VStack(spacing: 12 * uiScale) {
                    Text("Create your first playlist")
                        .foregroundColor(Color(white: 0.75))
                    Text("Group tracks into listening sets. Create a playlist, then select tracks in Library and choose Add to Playlist.")
                        .foregroundColor(Color(white: 0.45))
                        .multilineTextAlignment(.center)
                    Button("Create Playlist", action: beginCreatingPlaylist)
                        .buttonStyle(.plain)
                        .foregroundColor(.white)
                }
                .padding(24 * uiScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(spacing: 12 * uiScale) {
            Text(title)
                .foregroundColor(Color(white: 0.75))
            Text(message)
                .foregroundColor(Color(white: 0.45))
                .multilineTextAlignment(.center)
        }
        .padding(24 * uiScale)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trackList(for playlist: Playlist, layout: FileTableLayout) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { index, track in
                    playlistTrackRow(track, index: index, playlist: playlist, layout: layout)
                }
            }
            .padding(.vertical, 4 * uiScale)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isTrackListFocused)
        .onDeleteCommand {
            guard isTrackListFocused, focusedNameField == nil else { return }
            removeTracks(selectedPlaylistTracks, from: playlist)
        }
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
                    .foregroundColor(Color(white: 0.38))
            }
            Spacer()
        }
        .padding(.horizontal, 10 * uiScale)
        .padding(.vertical, 7 * uiScale)
        .background(isSelected ? Color.white.opacity(0.07) : (index.isMultiple(of: 2) ? Color(white: 0.032) : Color(white: 0.045)))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedPlaylistId = playlist.id
            isTrackListFocused = false
            statusMessage = nil
            actionError = nil
        }
        .contextMenu { playlistActions(for: playlist) }
    }

    private func detailHeader(for playlist: Playlist, layout: FileTableLayout) -> some View {
        let tracks = library.tracksForPlaylist(playlist.id)
        let compact = !layout.showArtist
        let isRenaming = renamingPlaylistId == playlist.id
        return VStack(alignment: .leading, spacing: 8 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                if isRenaming {
                    TextField("Playlist name", text: $editingName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 * uiScale, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .focused($focusedNameField, equals: .rename)
                        .onAppear { focusedNameField = .rename }
                        .onSubmit { savePlaylistName(playlist) }
                        .onExitCommand(perform: cancelRename)
                    if !compact { renameButtons(for: playlist) }
                } else {
                    Text(playlist.name)
                        .font(.system(size: 13 * uiScale, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }

                if !isRenaming || !compact {
                    playlistActionsMenu(for: playlist, compact: compact)
                }
            }

            if isRenaming && compact {
                HStack(spacing: 12 * uiScale) {
                    renameButtons(for: playlist)
                    Spacer(minLength: 0)
                    playlistActionsMenu(for: playlist, compact: true)
                }
            }

            if let renameError, isRenaming {
                Text(renameError)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12 * uiScale) {
                Text("\(tracks.count) tracks / \(formatDuration(totalDuration(tracks)))")
                    .foregroundColor(Color(white: 0.45))
                    .lineLimit(1)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !compact {
                    Button("PLAY") { playPlaylist(playlist) }
                        .foregroundColor(.white)
                    Button("QUEUE") { playback.enqueue(tracks) }
                        .foregroundColor(Color(white: 0.65))
                }
            }
            .buttonStyle(.plain)
            .disabled(tracks.isEmpty)

            if !searchQuery.isEmpty {
                HStack(spacing: 8 * uiScale) {
                    Text(compact ? "\(filteredTracks.count) shown · Reorder paused" : "\(filteredTracks.count) shown · Clear search to reorder tracks")
                        .foregroundColor(Color(white: 0.45))
                        .lineLimit(1)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Button {
                        searchText = ""
                    } label: {
                        if compact {
                            Image(systemName: "xmark.circle")
                        } else {
                            Text("CLEAR SEARCH")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(Color(white: 0.65))
                    .accessibilityLabel("Clear playlist search")
                    .help("Clear search to reorder tracks")
                }
                .font(.system(size: 8 * uiScale, design: .monospaced))
            }
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, 8 * uiScale)
        .background(Color(white: 0.025))
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private func renameButtons(for playlist: Playlist) -> some View {
        Button("Cancel", action: cancelRename)
            .buttonStyle(.plain)
            .foregroundColor(Color(white: 0.6))
            .fixedSize()
        Button("Save") { savePlaylistName(playlist) }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .disabled(editingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .fixedSize()
    }

    private func playlistActionsMenu(for playlist: Playlist, compact: Bool) -> some View {
        Menu {
            playlistActions(for: playlist)
        } label: {
            if compact {
                Image(systemName: "ellipsis")
                    .frame(width: 24 * uiScale, height: 16 * uiScale)
            } else {
                Text("ACTIONS")
            }
        }
        .foregroundColor(Color(white: 0.65))
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Actions for \(playlist.name)")
        .help("Playlist actions")
    }

    @ViewBuilder
    private func playlistActions(for playlist: Playlist) -> some View {
        Button("Play Playlist") { playPlaylist(playlist) }
            .disabled(playlist.tracks.isEmpty)
        Button("Add to Queue") { playback.enqueue(library.tracksForPlaylist(playlist.id)) }
            .disabled(playlist.tracks.isEmpty)
        Divider()
        Button("Rename Playlist…") { beginRenaming(playlist) }
        Divider()
        Button("Clear Playlist…") { pendingConfirmation = .clear(playlist) }
            .disabled(playlist.tracks.isEmpty)
        Button("Delete Playlist…") { pendingConfirmation = .delete(playlist) }
    }

    private func selectionBar(for playlist: Playlist, layout: FileTableLayout) -> some View {
        let selected = selectedPlaylistTracks
        let compact = !layout.showArtist
        return HStack(spacing: 12 * uiScale) {
            if selected.isEmpty {
                Text(compact ? "⌘/⇧-click to select tracks" : "⌘-click to select tracks · ⇧-click to select a range")
                    .foregroundColor(Color(white: 0.4))
                    .lineLimit(1)
                    .help("Command-click to toggle selection; Shift-click to select a range")
                Spacer(minLength: 0)
            } else {
                Text("\(selected.count) SELECTED")
                    .foregroundColor(Color(white: 0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !compact {
                    Button("QUEUE") { playback.enqueue(selected) }
                        .accessibilityLabel("Add selected tracks to queue")
                    Button("REMOVE FROM PLAYLIST") { removeTracks(selected, from: playlist) }
                        .help("Remove selected tracks from this playlist only. Library tracks and source files are kept.")
                }
                Menu("ACTIONS") {
                    TrackActionsMenu(tracks: selected, context: playlistTracks, title: playlist.name)
                    Divider()
                    Button("Remove from Playlist") { removeTracks(selected, from: playlist) }
                    Button("Deselect All") {
                        setSelection([], primary: nil)
                        selectionAnchorId = nil
                    }
                    if selected.count == 1, let track = selected.first {
                        Divider()
                        Button("Move Up") { moveTrack(track, in: playlist, by: -1) }
                            .disabled(!canMoveTrack(track, in: playlist, by: -1))
                        Button("Move Down") { moveTrack(track, in: playlist, by: 1) }
                            .disabled(!canMoveTrack(track, in: playlist, by: 1))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Selected track actions")
                if !compact {
                    Button("DESELECT") {
                        setSelection([], primary: nil)
                        selectionAnchorId = nil
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 8 * uiScale, weight: .medium, design: .monospaced))
        .foregroundColor(Color(white: 0.7))
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, 7 * uiScale)
        .background(Color(white: 0.035))
    }

    private func playlistTrackRow(_ track: Track, index: Int, playlist: Playlist, layout: FileTableLayout) -> some View {
        let isPlaying = playerState.currentTrack?.id == track.id
        let isSelected = playerState.selectedTrackIds.contains(track.id)
        let actionTracks = isSelected ? selectedPlaylistTracks : [track]
        return HStack(spacing: layout.spacing) {
            Text(isPlaying ? "\u{25B6}" : String(format: "%02d", index + 1))
                .foregroundColor(isPlaying ? .white : Color(white: 0.34))
                .frame(width: 28 * uiScale, alignment: .trailing)

            Text(track.displayTitle)
                .foregroundColor(isPlaying ? .white : Color(white: 0.76))
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if layout.showArtist {
                Text(track.artist ?? "Unknown Artist")
                    .foregroundColor(Color(white: 0.5))
                    .lineLimit(1)
                    .frame(width: layout.artistWidth, alignment: .leading)
            }

            Text(track.formattedDuration)
                .foregroundColor(Color(white: 0.34))
                .lineLimit(1)
                .frame(width: layout.durationWidth, alignment: .trailing)
        }
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, 6 * uiScale)
        .background(rowBackground(isPlaying: isPlaying, isSelected: isSelected, index: index))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selectTrack(track)
            playback.play(track: track, context: library.tracksForPlaylist(playlist.id), title: playlist.name)
        }
        .onTapGesture { selectTrack(track) }
        .contextMenu {
            TrackActionsMenu(tracks: actionTracks, context: playlistTracks, title: playlist.name)
            Divider()
            Button("Move Up") { moveTrack(track, in: playlist, by: -1) }
                .disabled(!canMoveTrack(track, in: playlist, by: -1))
            Button("Move Down") { moveTrack(track, in: playlist, by: 1) }
                .disabled(!canMoveTrack(track, in: playlist, by: 1))
            Button(actionTracks.count > 1 ? "Remove Selected Tracks from Playlist" : "Remove from Playlist") {
                removeTracks(actionTracks, from: playlist)
            }
        }
        .help("⌘-click to toggle selection; ⇧-click to select a range")
    }

    private func selectTrack(_ track: Track) {
        focusedNameField = nil
        isTrackListFocused = true
        let visibleIds = filteredTracks.map(\.id)
        let modifiers = NSEvent.modifierFlags
        let anchor = selectionAnchorId ?? playerState.selectedTrackId
        let ids = LibraryQuery.selection(
            clicked: track.id,
            visibleIDs: visibleIds,
            selected: playerState.selectedTrackIds.intersection(Set(visibleIds)),
            anchor: anchor,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift)
        )
        setSelection(ids, primary: ids.contains(track.id) ? track.id : playerState.selectedTrackId)
        if !modifiers.contains(.shift) || anchor == nil {
            selectionAnchorId = playerState.selectedTrackId
        }
    }

    private func setSelection(_ ids: Set<String>, primary: String?) {
        let resolvedPrimary = primary.flatMap { ids.contains($0) ? $0 : nil }
            ?? filteredTracks.first { ids.contains($0.id) }?.id
        // Set the group first: PlayerState's primary-selection observer preserves it when it contains the primary.
        playerState.selectedTrackIds = ids
        playerState.selectedTrackId = resolvedPrimary
    }

    private func synchronizeVisibleTracks(resetSelection: Bool = false) {
        let tracks = filteredTracks
        let visibleIds = Set(tracks.map(\.id))
        let retained = playerState.selectedTrackIds.intersection(visibleIds)
        let previousPrimary = playerState.selectedTrackId
        if resetSelection { playerState.selectedTrackId = nil }
        playerState.setVisibleTracks(tracks)
        if !resetSelection && !retained.isEmpty {
            setSelection(retained, primary: previousPrimary)
        } else {
            let primary = playerState.selectedTrackId
            setSelection(primary.map { Set([$0]) } ?? [], primary: primary)
        }
        if resetSelection || !visibleIds.contains(selectionAnchorId ?? "") {
            selectionAnchorId = playerState.selectedTrackId
        }
    }

    private func canMoveTrack(_ track: Track, in playlist: Playlist, by offset: Int) -> Bool {
        guard searchQuery.isEmpty,
              let index = playlist.tracks.firstIndex(of: track.id) else { return false }
        return playlist.tracks.indices.contains(index + offset)
    }

    private func moveTrack(_ track: Track, in playlist: Playlist, by offset: Int) {
        guard canMoveTrack(track, in: playlist, by: offset) else { return }
        library.moveTrackInPlaylist(playlistId: playlist.id, trackId: track.id, by: offset)
        actionError = library.lastError
    }

    private func removeTracks(_ tracks: [Track], from playlist: Playlist) {
        let ids = Set(tracks.map(\.id))
        guard !ids.isEmpty else { return }
        guard library.removeTracksFromPlaylist(trackIds: ids, playlistId: playlist.id) else {
            actionError = library.lastError ?? "Could not remove tracks from the playlist. Please try again."
            return
        }
        setSelection(playerState.selectedTrackIds.subtracting(ids), primary: playerState.selectedTrackId)
        actionError = nil
        statusMessage = "Removed \(tracks.count) \(tracks.count == 1 ? "track" : "tracks") from “\(playlist.name)”. Tracks remain in your library."
    }

    private func rowBackground(isPlaying: Bool, isSelected: Bool, index: Int) -> Color {
        if isSelected { return Color(red: 0.13, green: 0.13, blue: 0.18) }
        if isPlaying { return Color(red: 0.11, green: 0.13, blue: 0.12) }
        return index.isMultiple(of: 2) ? Color(white: 0.035) : Color(white: 0.048)
    }

    private func beginCreatingPlaylist() {
        cancelRename()
        newName = ""
        creationError = nil
        statusMessage = nil
        actionError = nil
        showNewPlaylist = true
        isTrackListFocused = false
        focusedNameField = .newPlaylist
    }

    private func cancelCreatingPlaylist() {
        showNewPlaylist = false
        newName = ""
        creationError = nil
        if focusedNameField == .newPlaylist { focusedNameField = nil }
    }

    private func createPlaylist() {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        creationError = nil
        let playlist = library.createPlaylist(name: trimmed)
        // The API also returns an unsaved draft on failure; only a published playlist is a success.
        guard library.playlists.contains(where: { $0.id == playlist.id }) else {
            creationError = library.lastError ?? "Could not create the playlist. Please try again."
            return
        }
        selectedPlaylistId = playlist.id
        searchText = ""
        cancelCreatingPlaylist()
        statusMessage = "Created “\(playlist.name)”. Add tracks from Library to get started."
    }

    private func beginRenaming(_ playlist: Playlist) {
        cancelCreatingPlaylist()
        selectedPlaylistId = playlist.id
        renamingPlaylistId = playlist.id
        editingName = playlist.name
        renameError = nil
        isTrackListFocused = false
        focusedNameField = .rename
    }

    private func cancelRename() {
        renamingPlaylistId = nil
        editingName = ""
        renameError = nil
        if focusedNameField == .rename { focusedNameField = nil }
    }

    private func savePlaylistName(_ playlist: Playlist) {
        let name = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard renamingPlaylistId == playlist.id, !name.isEmpty else { return }
        if name == playlist.name {
            cancelRename()
            return
        }
        library.renamePlaylist(id: playlist.id, name: name)
        guard library.lastError == nil,
              library.playlists.first(where: { $0.id == playlist.id })?.name == name else {
            renameError = library.lastError ?? "Could not rename the playlist. Please try again."
            return
        }
        cancelRename()
    }

    private func performConfirmedAction(_ confirmation: PlaylistConfirmation) {
        let playlist = confirmation.playlist
        let completedAction: String
        switch confirmation {
        case .clear:
            library.clearPlaylist(id: playlist.id)
            completedAction = "Cleared"
        case .delete:
            library.deletePlaylist(id: playlist.id)
            completedAction = "Deleted"
        }
        actionError = library.lastError
        guard actionError == nil else { return }
        if selectedPlaylist?.id == playlist.id {
            setSelection([], primary: nil)
            selectionAnchorId = nil
            cancelRename()
        }
        statusMessage = "\(completedAction) “\(playlist.name)”. Library tracks and source files were kept."
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
        let total = Int(min(d, Double(Int32.max)))
        let h = total / 3600
        let m = (total / 60) % 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}

private struct PlaylistTrackHeader: View {
    let layout: FileTableLayout

    var body: some View {
        HStack(spacing: layout.spacing) {
            Text("#").frame(width: 28 * layout.uiScale, alignment: .trailing)
            Text("TITLE")
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if layout.showArtist {
                Text("ARTIST").frame(width: layout.artistWidth, alignment: .leading)
            }
            Text("TIME").frame(width: layout.durationWidth, alignment: .trailing)
        }
        .lineLimit(1)
        .font(.system(size: 8 * layout.uiScale, weight: .medium, design: .monospaced))
        .foregroundColor(Color(white: 0.32))
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, 5 * layout.uiScale)
        .background(Color(white: 0.025))
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)
    }
}
