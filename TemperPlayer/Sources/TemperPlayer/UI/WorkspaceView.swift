import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @Environment(\.uiScale) var uiScale
    @Binding var hoveredTrackId: String?
    @Binding var activeMode: Mode
    @State private var searchText = ""
    @ObservedObject private var importService = ImportService.shared

    private var headerTitle: String {
        switch activeMode {
        case .library: return "LIBRARY"
        case .playlists: return "PLAYLISTS"
        default: return "~/Music"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))

                if activeMode == .files {
                    TextField("filter...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9 * uiScale, design: .monospaced))
                        .foregroundColor(.white)
                        .frame(maxWidth: 120 * uiScale)
                }

                Spacer()
                if importService.isImporting {
                    Text("importing \(importService.importedCount)/\(importService.foundCount)")
                        .font(.system(size: 8 * uiScale, design: .monospaced))
                        .foregroundColor(Color(red: 0.4, green: 0.8, blue: 0.4))
                }
                if activeMode == .files {
                    Text("\(library.tracks.count) files")
                        .font(.system(size: 9 * uiScale, design: .monospaced))
                        .foregroundColor(Color(white: 0.25))
                }
            }
            .padding(.horizontal, 16 * uiScale)
            .padding(.vertical, 8 * uiScale)
            .background(Color.black)

            switch activeMode {
            case .playlists:
                PlaylistListView(searchText: $searchText)
                    .frame(maxHeight: .infinity)
            case .library:
                LibraryBrowserView()
                    .frame(maxHeight: .infinity)
            default:
                FileTreeView(hoveredTrackId: $hoveredTrackId, searchText: searchText)
                    .frame(maxHeight: .infinity)
            }

            if playerState.currentTrack != nil {
                WaveformView()
                    .frame(height: 100 * uiScale)
                    .padding(.horizontal, 16 * uiScale)
                    .padding(.bottom, 8 * uiScale)
            }
        }
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
        )
    }
}
