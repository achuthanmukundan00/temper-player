import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @EnvironmentObject var actions: LibraryActions
    @ObservedObject private var importer = ImportService.shared
    @State private var isDropTargeted = false
    @Environment(\.uiScale) var uiScale
    @State private var activeMode: Mode = .files
    @State private var hoveredTrackId: String?
    @State private var keyMonitor: Any?
    @State private var hasWorkspace = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let inspectorWidth = min(260 * uiScale, max(190 * uiScale, width * 0.24))

            Group {
                if width < 320 {
                    SuperCompactPlayerView()
                        .background(WindowActivationView())
                } else if width < 580 {
                    CompactPlayerView()
                        .background(WindowActivationView())
                } else if width < 800 {
                    // Medium: no inspector, no visualizers
                    HStack(spacing: 0) {
                        GlyphSpine(activeMode: $activeMode)

                        WorkspaceView(hoveredTrackId: $hoveredTrackId, activeMode: $activeMode, showVisualizers: false)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TransportBar()
                            .frame(height: 34 * uiScale)
                    }
                    .background(WindowActivationView())
                } else {
                    HStack(spacing: 0) {
                        GlyphSpine(activeMode: $activeMode)

                        WorkspaceView(hoveredTrackId: $hoveredTrackId, activeMode: $activeMode, showVisualizers: true)
                            .frame(maxWidth: .infinity)
                            .layoutPriority(1)

                        InspectorView(hoveredTrackId: hoveredTrackId)
                            .frame(width: inspectorWidth)
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        TransportBar()
                            .frame(height: 34 * uiScale)
                    }
                    .background(WindowActivationView())
                }
            }
            .onAppear { hasWorkspace = width >= 580 }
            .onChange(of: width) { _, width in hasWorkspace = width >= 580 }
        }
        .background(Color.black)
        .onAppear {
            ImportService.shared.setDatabase(library)
            installKeyMonitor()
            NSApp.setActivationPolicy(.regular)
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            importer.importURLs(files)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3)
                    .padding(4).allowsHitTesting(false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { statusBanner }
        .sheet(isPresented: $actions.showingManager) { LibraryManagerView() }
        .sheet(isPresented: $actions.isCreatingPlaylist) { NewPlaylistSheet() }
        .sheet(isPresented: $actions.showingQueue) { QueueView() }
        .alert("Remove \(actions.removalTracks.count) tracks from the library?", isPresented: $actions.isConfirmingRemoval) {
            Button("Cancel", role: .cancel) { actions.removalTracks = [] }
            Button("Remove from Library", role: .destructive) {
                playback.removeLibraryTracks(ids: Set(actions.removalTracks.map(\.id)))
                actions.removalTracks = []
            }
        } message: {
            Text("This removes the entries from playlists, the queue, and play history. Your original audio files are kept. This cannot be undone; you can import the files again.")
        }
        .onReceive(library.$tracks) { _ in
            DispatchQueue.main.async { playback.reconcileLibraryTracks() }
        }
        .onReceive(audioManager.$currentTime) { t in
            playerState.currentTime = t
        }
        .onReceive(audioManager.$isPlaying) { p in
            playerState.isPlaying = p
            if p { playerState.duration = audioManager.duration }
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        VStack(spacing: 0) {
            if importer.isImporting {
                HStack {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Importing \(importer.importedCount) / \(importer.foundCount)")
                        Text(importer.currentFile).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Cancel") { importer.cancelImport() }
                }
                .padding(10)
            } else if let summary = importer.importSummary {
                messageBanner(summary, isError: false) { importer.importSummary = nil }
            }
            if let error = library.lastError {
                messageBanner(error, isError: true) { library.lastError = nil }
            }
            if let error = playback.playbackError {
                messageBanner(error, isError: true) { playback.playbackError = nil }
            }
        }
        .font(.callout)
        .background(Color(white: 0.08))
    }

    private func messageBanner(_ text: String, isError: Bool, dismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top) {
            Image(systemName: isError ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(isError ? .orange : .secondary)
            Text(text).textSelection(.enabled)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss message").accessibilityLabel("Dismiss message")
        }
        .padding(10)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isTextInputActive, event.window === NSApp.mainWindow,
                  NSApp.modalWindow == nil, event.window?.attachedSheet == nil,
                  !actions.isConfirmingRemoval else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            let isBrowsing = hasWorkspace && (activeMode == .files || activeMode == .library || activeMode == .playlists)
            if modifiers == .command, event.keyCode == 123 { playback.previous(); return nil }
            if modifiers == .command, event.keyCode == 124 { playback.next(); return nil }
            if isBrowsing, modifiers == .command, event.keyCode == 0, activeMode == .files || activeMode == .library {
                playerState.selectedTrackIds = Set(playerState.visibleTracks.map(\.id))
                return nil
            }
            if isBrowsing, (modifiers.isEmpty || modifiers == .command), event.keyCode == 51,
               activeMode == .files || activeMode == .library {
                actions.requestRemoval(playerState.visibleTracks.filter { playerState.selectedTrackIds.contains($0.id) })
                return nil
            }
            guard modifiers.isEmpty else { return event }

            switch event.keyCode {
            case 49:
                playback.togglePlayPause()
                return nil
            case 123:
                playback.seek(by: -5)
                return nil
            case 124:
                playback.seek(by: 5)
                return nil
            case 125:
                guard isBrowsing else { return event }
                playerState.selectVisibleTrack(offset: 1)
                return nil
            case 126:
                guard isBrowsing else { return event }
                playerState.selectVisibleTrack(offset: -1)
                return nil
            case 36:
                guard isBrowsing else { return event }
                if let track = playerState.selectedVisibleTrack {
                    playback.play(track: track, context: playerState.visibleTracks, title: activeMode == .playlists ? "Playlist" : "Library")
                    return nil
                }
                return event
            case 12: // 'q' keycode — enqueue selected track
                guard isBrowsing else { return event }
                if let track = playerState.selectedVisibleTrack {
                    playback.enqueue(track)
                    return nil
                }
                return event
            default:
                return event
            }
        }
    }

    private var isTextInputActive: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }
}

private struct WindowActivationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
