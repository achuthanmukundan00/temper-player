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
    }
}
