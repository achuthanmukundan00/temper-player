import SwiftUI

@main
struct TemperPlayerApp: App {
    @StateObject private var audioManager: AudioManager
    @StateObject private var library: Database
    @StateObject private var playerState: PlayerState
    @StateObject private var playback: PlaybackController
    @AppStorage("uiScale") private var uiScale: Double = 1.15
    private let menuBarController: MenuBarController

    init() {
        let audioManager = AudioManager()
        let library = Database()
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
            NSApp.activate(ignoringOtherApps: true)
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
                Button("Import Folder\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    ImportService.shared.importFolder(url: url)
                }
                .keyboardShortcut("o", modifiers: .command)
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

class PlayerState: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var queueIndex: Int?
    @Published var queueTitle = "Queue"
    @Published var visibleTracks: [Track] = []
    @Published var selectedTrackId: String?
    @Published var selectedTrackIds: Set<String> = []
    @Published var volume: Float = 1.0

    var upcomingQueue: [Track] {
        guard let queueIndex else { return queue }
        guard queueIndex + 1 < queue.count else { return [] }
        return Array(queue[(queueIndex + 1)...])
    }

    var hasPreviousTrack: Bool {
        guard let queueIndex else { return false }
        return queueIndex > 0
    }

    var hasNextTrack: Bool {
        guard let queueIndex else { return !queue.isEmpty }
        return queueIndex + 1 < queue.count
    }

    var timeString: String {
        let m = Int(currentTime) / 60
        let s = Int(currentTime) % 60
        return String(format: "%d:%02d", m, s)
    }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    var displayPath: String {
        guard let t = currentTrack else { return "no buffer loaded" }
        let url = URL(fileURLWithPath: t.path)
        let dir = url.deletingLastPathComponent().lastPathComponent
        return "\(dir)/\(url.lastPathComponent)"
    }

    func prepareToPlay(track: Track, context: [Track], title: String) {
        let resolvedContext = context.isEmpty ? [track] : context
        if let index = resolvedContext.firstIndex(where: { $0.id == track.id }) {
            queue = resolvedContext
            queueIndex = index
        } else {
            queue = [track] + resolvedContext
            queueIndex = 0
        }
        queueTitle = title
        setCurrent(track)
    }

    func enqueue(_ track: Track) {
        ensureCurrentQueue()
        queue.append(track)
    }

    func enqueue(_ tracks: [Track]) {
        ensureCurrentQueue()
        queue.append(contentsOf: tracks)
    }

    func enqueueNext(_ track: Track) {
        ensureCurrentQueue()
        if queueIndex == nil {
            queue.insert(track, at: 0)
        } else {
            let insertIndex = min((queueIndex ?? -1) + 1, queue.count)
            queue.insert(track, at: max(0, insertIndex))
        }
    }

    func advanceToNext() -> Track? {
        ensureCurrentQueue()
        if queueIndex == nil, let first = queue.first {
            queueIndex = 0
            setCurrent(first)
            return first
        }
        guard let index = queueIndex, index + 1 < queue.count else { return nil }
        queueIndex = index + 1
        let next = queue[index + 1]
        setCurrent(next)
        return next
    }

    func retreatToPrevious() -> Track? {
        guard currentTime <= 3, let index = queueIndex, index > 0 else {
            currentTime = 0
            return currentTrack
        }
        queueIndex = index - 1
        let previous = queue[index - 1]
        setCurrent(previous)
        return previous
    }

    func playQueueItem(at index: Int) -> Track? {
        guard queue.indices.contains(index) else { return nil }
        queueIndex = index
        let track = queue[index]
        setCurrent(track)
        return track
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queue.remove(at: index)

        if queue.isEmpty {
            queueIndex = nil
            queueTitle = "Queue"
            return
        }

        guard let currentIndex = queueIndex else { return }
        if index < currentIndex {
            queueIndex = currentIndex - 1
        } else if index == currentIndex {
            queueIndex = min(currentIndex, queue.count - 1)
            setCurrent(queue[queueIndex ?? 0])
        }
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard source != destination,
              queue.indices.contains(source),
              queue.indices.contains(destination) else { return }
        let track = queue.remove(at: source)
        queue.insert(track, at: destination)
        if let qi = queueIndex {
            if source == qi {
                queueIndex = destination
            } else if source < qi && destination >= qi {
                queueIndex = qi - 1
            } else if source > qi && destination <= qi {
                queueIndex = qi + 1
            }
        }
    }

    func clearUpcomingQueue() {
        guard let currentTrack else {
            queue.removeAll()
            queueIndex = nil
            queueTitle = "Queue"
            return
        }
        queue = [currentTrack]
        queueIndex = 0
        queueTitle = "Queue"
    }

    func finishCurrentTrack() {
        currentTime = duration
        isPlaying = false
    }

    func setVisibleTracks(_ tracks: [Track]) {
        visibleTracks = tracks
        if let selectedTrackId, tracks.contains(where: { $0.id == selectedTrackId }) {
            return
        }
        if let currentTrack, tracks.contains(where: { $0.id == currentTrack.id }) {
            selectedTrackId = currentTrack.id
        } else {
            selectedTrackId = tracks.first?.id
        }
    }

    func selectVisibleTrack(offset: Int) {
        guard !visibleTracks.isEmpty else { return }
        let currentIndex = selectedTrackId.flatMap { id in
            visibleTracks.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = max(0, min(visibleTracks.count - 1, currentIndex + offset))
        selectedTrackId = visibleTracks[nextIndex].id
    }

    var selectedVisibleTrack: Track? {
        guard let selectedTrackId else { return visibleTracks.first }
        return visibleTracks.first { $0.id == selectedTrackId } ?? visibleTracks.first
    }

    private func setCurrent(_ track: Track) {
        currentTrack = track
        duration = track.duration
        currentTime = 0
    }

    private func ensureCurrentQueue() {
        guard queue.isEmpty, let currentTrack else { return }
        queue = [currentTrack]
        queueIndex = 0
    }
}
