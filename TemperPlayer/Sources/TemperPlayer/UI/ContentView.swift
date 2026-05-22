import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @Environment(\.uiScale) var uiScale
    @State private var activeMode: Mode = .files
    @State private var hoveredTrackId: String?

    var body: some View {
        HStack(spacing: 0) {
            GlyphSpine(activeMode: $activeMode)

            WorkspaceView(hoveredTrackId: $hoveredTrackId, activeMode: $activeMode)
                .frame(minWidth: 380 * uiScale)

            InspectorView(hoveredTrackId: hoveredTrackId)
                .frame(width: 210 * uiScale)
        }
        .overlay(alignment: .bottom) {
            TransportBar()
                .frame(height: 34 * uiScale)
        }
        .background(Color.black)
        .onDrop(of: [.fileURL], delegate: ImportDropDelegate())
        .onReceive(audioManager.$currentTime) { t in
            playerState.currentTime = t
        }
        .onReceive(audioManager.$isPlaying) { p in
            playerState.isPlaying = p
            if p { playerState.duration = audioManager.duration }
        }
        .background {
            Button("") {
                if playerState.isPlaying {
                    audioManager.pause()
                } else if playerState.currentTrack != nil {
                    audioManager.resume()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .hidden()
        }
        .background {
            Button("") {
                audioManager.seek(to: max(0, playerState.currentTime - 5))
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .hidden()
        }
        .background {
            Button("") {
                audioManager.seek(to: min(playerState.duration, playerState.currentTime + 5))
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .hidden()
        }
    }
}
