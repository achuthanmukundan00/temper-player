import SwiftUI

struct MetadataEditorView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var library: Database

    private var tracks: [Track] {
        let selected = library.tracks.filter { playerState.selectedTrackIds.contains($0.id) }
        if !selected.isEmpty { return selected }
        if let id = playerState.currentTrack?.id, let track = library.tracks.first(where: { $0.id == id }) { return [track] }
        return []
    }

    var body: some View {
        if tracks.isEmpty {
            ContentUnavailableView("Select tracks to edit", systemImage: "tag", description: Text("Select one or more tracks in Files, Library, or Playlists, then open Metadata."))
        } else {
            MetadataForm(tracks: tracks)
                .id(tracks.map(\.id).sorted().joined(separator: ":"))
        }
    }
}

private struct MetadataForm: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playback: PlaybackController
    let tracks: [Track]
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var changeTitle = false
    @State private var changeArtist = false
    @State private var changeAlbum = false
    @State private var saved = false

    private var multiple: Bool { tracks.count > 1 }
    private var hasChanges: Bool { !multiple || changeTitle || changeArtist || changeAlbum }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(multiple ? "Edit \(tracks.count) tracks" : "Edit Track").font(.title3.bold())
                Text("Changes are saved to your TemperPlayer library only. Audio files and their embedded tags are not modified.")
                    .font(.callout).foregroundStyle(.secondary)
                if multiple {
                    Text("Check the fields to change. Unchecked fields stay unchanged; a checked empty field clears that value.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                field("Title", value: $title, enabled: $changeTitle)
                field("Artist", value: $artist, enabled: $changeArtist)
                field("Album", value: $album, enabled: $changeAlbum)
                HStack {
                    Button("Reset", action: reset)
                    Spacer()
                    if saved { Text("Saved to library").foregroundStyle(.green).font(.caption) }
                    Button("Save Changes", action: save).disabled(!hasChanges)
                }
                if let track = tracks.first, !multiple {
                    Divider()
                    Text("File Information").font(.headline)
                    info("File", track.path)
                    info("Format", "\(track.format.uppercased()) · \(track.sampleRate) Hz · \(track.channels) channels")
                    info("Duration", track.formattedDuration)
                    info("Size", ByteCountFormatter.string(fromByteCount: Int64(track.fileSize), countStyle: .file))
                    if let albumArtist = track.albumArtist { info("Album artist", albumArtist) }
                    if let number = track.trackNo { info("Track", String(number)) }
                    if let number = track.discNo { info("Disc", String(number)) }
                    if let year = track.year { info("Year", String(year)) }
                    if let genre = track.genre { info("Genre", genre) }
                    info("Play count", String(track.playCount))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: track.path)]) }
                }
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reset)
        .onChange(of: title) { _, _ in saved = false }
        .onChange(of: artist) { _, _ in saved = false }
        .onChange(of: album) { _, _ in saved = false }
    }

    private func field(_ label: String, value: Binding<String>, enabled: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if multiple { Toggle("Change \(label.lowercased())", isOn: enabled) }
            else { Text(label).font(.caption).foregroundStyle(.secondary) }
            TextField(label, text: value).textFieldStyle(.roundedBorder)
                .disabled(multiple && !enabled.wrappedValue)
        }
    }

    private func info(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func reset() {
        title = multiple ? "" : tracks.first?.title ?? ""
        artist = multiple ? "" : tracks.first?.artist ?? ""
        album = multiple ? "" : tracks.first?.album ?? ""
        changeTitle = false
        changeArtist = false
        changeAlbum = false
        saved = false
    }

    private func save() {
        guard hasChanges else { return }
        library.lastError = nil
        if multiple {
            library.batchUpdateTrackMetadata(ids: tracks.map(\.id), title: changeTitle ? title : nil,
                                             artist: changeArtist ? artist : nil, album: changeAlbum ? album : nil)
        } else if let track = tracks.first {
            library.updateTrackMetadata(id: track.id, title: title, artist: artist, album: album)
        }
        saved = library.lastError == nil
        if saved { playback.reconcileLibraryTracks() }
    }
}
