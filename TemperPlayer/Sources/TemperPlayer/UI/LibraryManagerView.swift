import SwiftUI

struct LibraryManagerView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var importer = ImportService.shared
    @State private var missingIDs: Set<String> = []
    @State private var checking = false
    @State private var checked = false
    @State private var pendingRemoval: [Track] = []
    @State private var confirmRemoval = false
    @State private var refreshID = UUID()

    private var folders: [String] { Array(Set(library.tracks.map(\.folderPath))).sorted() }
    private var missingTracks: [Track] { library.tracks.filter { missingIDs.contains($0.id) } }
    private var scanKey: String { refreshID.uuidString + library.tracks.map { $0.id + $0.path }.sorted().joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Manage Library").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("\(library.tracks.count) tracks · \(library.playlists.count) playlists · \(folders.count) folders")
                .foregroundStyle(.secondary)
            Text("TemperPlayer references your files in place. Removing entries here never moves or deletes your audio files.")
                .font(.callout)
            if let error = library.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            List {
                Section("Folders containing library tracks") {
                    if folders.isEmpty { Text("Import music to start your library.").foregroundStyle(.secondary) }
                    ForEach(folders, id: \.self) { folder in
                        folderRow(folder)
                    }
                }
                Section("Missing files") {
                    Text("Reconnect external drives before removing missing entries. Permissions or an offline disk can make files appear missing.")
                        .font(.caption).foregroundStyle(.secondary)
                    if checking {
                        ProgressView("Checking file locations…")
                    } else if checked && missingTracks.isEmpty {
                        Label("All library files are available", systemImage: "checkmark.circle")
                    }
                    ForEach(missingTracks) { track in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(track.displayTitle)
                            Text(track.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.inset)
            HStack {
                Button("Import Music…") { importer.presentImportPanel() }.disabled(importer.isImporting)
                Button("Check Again") { refreshID = UUID() }.disabled(checking)
                Spacer()
                Button("Remove Missing Entries…", role: .destructive) { requestRemoval(missingTracks) }
                    .disabled(checking || missingTracks.isEmpty || importer.isImporting)
            }
        }
        .padding(24)
        .frame(minWidth: 600, idealWidth: 700, minHeight: 440, idealHeight: 540)
        .task(id: scanKey) { await scanMissing() }
        .alert("Remove \(pendingRemoval.count) tracks from the library?", isPresented: $confirmRemoval) {
            Button("Cancel", role: .cancel) { pendingRemoval = [] }
            Button("Remove from Library", role: .destructive) {
                if playback.removeLibraryTracks(ids: Set(pendingRemoval.map(\.id))) { pendingRemoval = [] }
            }
        } message: {
            Text("This removes the entries from playlists, the queue, and play history. Your original audio files are kept. This cannot be undone; you can import the files again.")
        }
    }

    private func folderRow(_ folder: String) -> some View {
        let tracks = library.tracks.filter { $0.folderPath == folder }
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: folder).lastPathComponent).fontWeight(.medium)
                Text(folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("\(tracks.count) tracks").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Actions") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
                }
                Button("Scan for New Music") { importer.importURLs([URL(fileURLWithPath: folder)]) }
                    .disabled(importer.isImporting)
                Divider()
                Button("Remove Folder’s Tracks…", role: .destructive) { requestRemoval(tracks) }
                    .disabled(importer.isImporting)
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private func requestRemoval(_ tracks: [Track]) {
        pendingRemoval = tracks
        confirmRemoval = !tracks.isEmpty
    }

    private func scanMissing() async {
        checking = true
        let snapshot = library.tracks
        let missing = await Task.detached(priority: .utility) {
            Set(snapshot.filter { !FileManager.default.isReadableFile(atPath: $0.path) }.map(\.id))
        }.value
        guard !Task.isCancelled else { return }
        missingIDs = missing
        checked = true
        checking = false
    }
}
