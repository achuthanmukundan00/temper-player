import SwiftUI

@main
struct TemperPlayerApp: App {
    @StateObject private var audioManager: AudioManager
    @StateObject private var library: Database
    @StateObject private var playerState: PlayerState
    @StateObject private var playback: PlaybackController
    @StateObject private var libraryActions = LibraryActions()
    @AppStorage("uiScale") private var uiScale: Double = 1.15
    private let menuBarController: MenuBarController

    init() {
        let audioManager = AudioManager()
        let library = Database(databaseURL: LibraryStorage.directory.appendingPathComponent("library.db"))
        let playerState = PlayerState()
        let playback = PlaybackController(
            audioManager: audioManager,
            library: library,
            playerState: playerState
        )

        _audioManager = StateObject(wrappedValue: audioManager)
        _library = StateObject(wrappedValue: library)
        _playerState = StateObject(wrappedValue: playerState)
        _playback = StateObject(wrappedValue: playback)

        ImportService.shared.setDatabase(library)

        menuBarController = MenuBarController(
            playerState: playerState,
            audioManager: audioManager,
            playback: playback,
            library: library,
            importService: ImportService.shared
        )

        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        Window("TemperPlayer", id: "main") {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(audioManager.analyzer)
                .environmentObject(library)
                .environmentObject(playerState)
                .environmentObject(playback)
                .environmentObject(libraryActions)
                .environment(\.uiScale, CGFloat(effectiveUIScale))
                .preferredColorScheme(.dark)
                .onAppear {
                    if uiScale > 3.0 || uiScale < 0.6 { uiScale = 1.15 }
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Files or Folders…") {
                    ImportService.shared.presentImportPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Library") {
                Button("New Playlist…") { libraryActions.requestPlaylist([]) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Manage Library…") { libraryActions.presentManager() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Show Queue…") { libraryActions.presentQueue() }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
            }
            CommandMenu("Playback") {
                Button(playerState.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                Button("Previous Track") { playback.previous() }
                Button("Next Track") { playback.next() }
                Divider()
                Button(playerState.isShuffled ? "Turn Shuffle Off" : "Turn Shuffle On") { playback.toggleShuffle() }
                Button("Cycle Repeat Mode") { playback.cycleRepeatMode() }
            }
            CommandMenu("View") {
                Button("Zoom In") { uiScale = min(3.0, uiScale + 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { uiScale = max(0.6, uiScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Zoom") { uiScale = 1.15 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    private var effectiveUIScale: Double {
        min(3.0, max(0.68, uiScale * nativeDisplayScale))
    }

    private var nativeDisplayScale: Double {
        guard let screen = NSScreen.main else { return 1.0 }
        if screen.backingScaleFactor >= 2 {
            return screen.visibleFrame.height <= 900 ? 0.84 : 0.9
        }
        return screen.visibleFrame.height <= 850 ? 0.9 : 1.0
    }
}
