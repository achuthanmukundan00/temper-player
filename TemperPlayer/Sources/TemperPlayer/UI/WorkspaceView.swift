import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var library: Database
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
        default: return "~/Music"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(headerTitle)
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))

                if activeMode == .files || activeMode == .playlists {
                    TextField("filter...", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 9 * uiScale, design: .monospaced))
                        .foregroundColor(.white)
                        .focused($searchFocused)
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
            case .tag:
                TagEditorView()
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
        if activeMode != .files && activeMode != .playlists {
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
            .padding(.bottom, 38 * uiScale)
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

private struct TagEditorView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var library: Database
    @Environment(\.uiScale) var uiScale

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10 * uiScale) {
                if let track = playerState.selectedTrackIds.count > 1 ? nil : (playerState.selectedTrackId.flatMap { id in library.tracks.first { $0.id == id } } ?? playerState.currentTrack) {
                    TagField(label: "title", value: track.title ?? "") { newValue in
                        library.updateTrackMetadata(id: track.id, title: newValue.isEmpty ? nil : newValue, artist: nil, album: nil)
                    }
                    TagField(label: "artist", value: track.artist ?? "") { newValue in
                        library.updateTrackMetadata(id: track.id, title: nil, artist: newValue.isEmpty ? nil : newValue, album: nil)
                    }
                    TagField(label: "album", value: track.album ?? "") { newValue in
                        library.updateTrackMetadata(id: track.id, title: nil, artist: nil, album: newValue.isEmpty ? nil : newValue)
                    }
                    if let aa = track.albumArtist { TagField(label: "album artist", value: aa) { _ in } }
                    if let tn = track.trackNo, tn > 0 { TagField(label: "track", value: "\(tn)") { _ in } }
                    if let dn = track.discNo, dn > 0 { TagField(label: "disc", value: "\(dn)") { _ in } }
                    if let y = track.year, y > 0 { TagField(label: "year", value: "\(y)") { _ in } }
                    if let g = track.genre { TagField(label: "genre", value: g) { _ in } }
                    TagField(label: "format", value: track.format.uppercased()) { _ in }
                    TagField(label: "sample rate", value: track.sampleRate >= 1000 ? "\(track.sampleRate / 1000).\(track.sampleRate % 1000 / 100)k" : "\(track.sampleRate)") { _ in }
                    TagField(label: "duration", value: durationString(track.duration)) { _ in }
                } else {
                    VStack(spacing: 8 * uiScale) {
                        Text("\u{25CE}")
                            .font(.system(size: 24 * uiScale))
                            .foregroundColor(Color(white: 0.2))
                        Text("select a track to edit metadata")
                            .font(.system(size: 10 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40 * uiScale)
                }
            }
            .padding(16 * uiScale)
        }
        .background(Color.black)
    }

    private func durationString(_ d: Double) -> String {
        guard d.isFinite, d > 0 else { return "--:--" }
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct TagField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var editValue = ""
    @Environment(\.uiScale) var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 2 * uiScale) {
            Text(label)
                .font(.system(size: 8 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.3))
            if editing {
                TextField("", text: $editValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundColor(.white)
                    .onSubmit {
                        onCommit(editValue)
                        editing = false
                    }
                    .onExitCommand { editing = false }
            } else {
                Text(value)
                    .font(.system(size: 11 * uiScale, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .onTapGesture {
                        editValue = value
                        editing = true
                    }
            }
            Rectangle().fill(Color(white: 0.08)).frame(height: 1)
        }
    }
}
