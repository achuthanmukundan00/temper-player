import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    @State private var activeMode: Mode = .files
    @State private var hoveredTrackId: String?
    @State private var keyMonitor: Any?

    var body: some View {
        GeometryReader { geo in
            let inspectorWidth = min(260 * uiScale, max(190 * uiScale, geo.size.width * 0.24))

            HStack(spacing: 0) {
                GlyphSpine(activeMode: $activeMode)

                WorkspaceView(hoveredTrackId: $hoveredTrackId, activeMode: $activeMode)
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)

                InspectorView(hoveredTrackId: hoveredTrackId)
                    .frame(width: inspectorWidth)
            }
            .overlay(alignment: .bottom) {
                TransportBar()
                    .frame(height: 34 * uiScale)
            }
            .background(WindowActivationView())
        }
        .background(Color.black)
        .onAppear {
            ImportService.shared.setDatabase(library)
            installKeyMonitor()
        }
        .onDisappear {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadObject(ofClass: NSURL.self) { item, error in
                    guard error == nil else { return }
                    if let nsurl = item as? NSURL {
                        let url = nsurl as URL
                        DispatchQueue.main.async {
                            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                ImportService.shared.importFolder(url: url)
                            } else {
                                ImportService.shared.importTrack(url: url)
                            }
                        }
                    }
                }
            }
            return true
        }
        .onReceive(audioManager.$currentTime) { t in
            playerState.currentTime = t
        }
        .onReceive(audioManager.$isPlaying) { p in
            playerState.isPlaying = p
            if p { playerState.duration = audioManager.duration }
        }
        .background(Group {
            Button("") {
                playback.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            Button("") { playback.seek(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { playback.seek(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }.hidden())
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !isTextInputActive else { return event }
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }

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
                playerState.selectVisibleTrack(offset: 1)
                return nil
            case 126:
                playerState.selectVisibleTrack(offset: -1)
                return nil
            case 36:
                if let track = playerState.selectedVisibleTrack {
                    playback.play(track: track, context: playerState.visibleTracks, title: activeMode == .playlists ? "Playlist" : "Library")
                    return nil
                }
                return event
            case 12: // 'q' keycode — enqueue selected track
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
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // No-op: activation only on make, not on every layout update.
    }
}
