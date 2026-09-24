import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var actions: LibraryActions
    @EnvironmentObject var playerState: PlayerState
    @Environment(\.uiScale) var uiScale
    @Binding var hoveredTrackId: String?
    @Binding var activeMode: Mode
    let showVisualizers: Bool
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @ObservedObject private var importService = ImportService.shared

    private var headerTitle: String {
        switch activeMode {
        case .library: return "LIBRARY"
        case .playlists: return "PLAYLISTS"
        case .tag: return "METADATA"
        case .analyze: return "ANALYZE"
        default: return "FILES"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))

                if activeMode == .files || activeMode == .playlists || activeMode == .library {
                    TextField("Search music…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9 * uiScale, design: .monospaced))
                        .foregroundColor(.white)
                        .focused($searchFocused)
                        .frame(maxWidth: 210 * uiScale)
                        .accessibilityLabel("Search music")
                }

                Spacer()
                Button { importService.presentImportPanel() } label: {
                    Label("Import", systemImage: "plus")
                }
                .help("Import audio files or folders (⌘O)")
                .disabled(importService.isImporting)
                Button { actions.presentQueue() } label: {
                    Image(systemName: "list.bullet")
                }
                .help("Show full play queue")
                .accessibilityLabel("Show Queue")
                Button { actions.presentManager() } label: {
                    Image(systemName: "folder.badge.gearshape")
                }
                .help("Manage library folders and missing files")
                .accessibilityLabel("Manage Library")
            }
            .padding(.horizontal, 16 * uiScale)
            .padding(.vertical, 6 * uiScale)
            .background(Color.black)

            switch activeMode {
            case .playlists:
                PlaylistListView(searchText: $searchText)
                    .frame(maxHeight: .infinity)
            case .library:
                LibraryBrowserView(searchText: searchText)
                    .frame(maxHeight: .infinity)
            case .tag:
                MetadataEditorView()
                    .frame(maxHeight: .infinity)
            case .analyze:
                visualizerContent
                    .frame(maxHeight: .infinity)
            default:
                FileTreeView(hoveredTrackId: $hoveredTrackId, searchText: searchText)
                    .frame(maxHeight: .infinity)
            }

            if activeMode != .analyze {
                visualizerDeck
            }
        }
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
        )
        .background(Group {
            Button("") { focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Button("") {
                if searchFocused || !searchText.isEmpty {
                    searchText = ""
                    searchFocused = false
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
        }.hidden())
        .onAppear {
            DispatchQueue.main.async {
                searchFocused = false
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func focusSearch() {
        if activeMode != .files && activeMode != .playlists && activeMode != .library {
            activeMode = .files
        }
        DispatchQueue.main.async { searchFocused = true }
    }

    @ViewBuilder
    private var visualizerDeck: some View {
        if showVisualizers, activeMode != .analyze, playerState.currentTrack != nil {
            VStack(spacing: 6 * uiScale) {
                PlayBar()
                    .padding(.horizontal, 12 * uiScale)

                HStack(alignment: .top, spacing: 7 * uiScale) {
                    VStack(spacing: 6 * uiScale) {
                        SpectrogramView()
                        MultibandWaveformView()
                    }
                        .frame(maxWidth: .infinity)

                    VStack(spacing: 6 * uiScale) {
                        MBGoniometerView()
                        MBCorrelationMeter()
                    }
                    .frame(width: 132 * uiScale)
                }
                .padding(.horizontal, 12 * uiScale)
            }
            .padding(.top, 6 * uiScale)
            .padding(.bottom, 28 * uiScale)
            .background(Color.black)
            .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .top)
        }
    }

    @ViewBuilder
    private var visualizerContent: some View {
        VStack(spacing: 10 * uiScale) {
            Spacer()

            PlayBar()
                .padding(.horizontal, 24 * uiScale)

            HStack(alignment: .top, spacing: 10 * uiScale) {
                VStack(spacing: 10 * uiScale) {
                    SpectrogramView()
                    MultibandWaveformView()
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: 10 * uiScale) {
                    MBGoniometerView()
                    MBCorrelationMeter()
                    MBLevelMeter()
                }
                .frame(width: 160 * uiScale)
            }
            .padding(.horizontal, 24 * uiScale)

            Spacer()
        }
    }
}
