import SwiftUI

@main
struct TemperPlayerApp: App {
    @StateObject private var audioManager = AudioManager()
    @StateObject private var library = Database()
    @StateObject private var playerState = PlayerState()
    @AppStorage("uiScale") private var uiScale: Double = 1.0

    init() {
        ImportService.shared.setDatabase(_library.wrappedValue)
    }

    var body: some Scene {
        Window("TemperPlayer", id: "main") {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(library)
                .environmentObject(playerState)
                .environment(\.uiScale, CGFloat(uiScale))
                .preferredColorScheme(.dark)
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
                Button("Zoom In") { uiScale = min(2.0, uiScale + 0.1) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { uiScale = max(0.5, uiScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Zoom") { uiScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}

class PlayerState: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var volume: Float = 0.75

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
}
