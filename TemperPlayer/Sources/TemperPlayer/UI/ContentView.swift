import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @State private var activeMode: Mode = .files
    @State private var hoveredTrackId: String?

    var body: some View {
        HStack(spacing: 0) {
            GlyphSpine(activeMode: $activeMode)

            WorkspaceView(hoveredTrackId: $hoveredTrackId)
                .frame(minWidth: 380)

            InspectorView(hoveredTrackId: hoveredTrackId)
                .frame(width: 210)
        }
        .overlay(alignment: .bottom) {
            TransportBar()
                .frame(height: 34)
        }
        .background(Color.black)
        .onDrop(of: [.fileURL], delegate: ImportDropDelegate())
    }
}
