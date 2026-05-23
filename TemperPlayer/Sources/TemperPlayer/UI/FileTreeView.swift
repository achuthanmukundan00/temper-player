import SwiftUI

struct FileTreeView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    @Binding var hoveredTrackId: String?
    let searchText: String

    private var filteredTracks: [Track] {
        guard !searchText.isEmpty else { return library.tracks }
        let q = searchText.lowercased()
        return library.tracks.filter {
            ($0.title?.lowercased().contains(q) ?? false) ||
            ($0.artist?.lowercased().contains(q) ?? false) ||
            ($0.album?.lowercased().contains(q) ?? false) ||
            $0.path.lowercased().contains(q)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let layout = FileTableLayout(width: geo.size.width, uiScale: uiScale)

            VStack(spacing: 0) {
                FileTableHeader(layout: layout)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredTracks.enumerated()), id: \.element.id) { idx, track in
                            FileTreeRow(
                                track: track,
                                index: idx,
                                isPlaying: playerState.currentTrack?.id == track.id,
                                isQueued: playerState.upcomingQueue.contains(where: { $0.id == track.id }),
                                isSelected: playerState.selectedTrackIds.contains(track.id),
                                isHovered: hoveredTrackId == track.id,
                                layout: layout
                            )
                            .onHover { hovering in
                                hoveredTrackId = hovering ? track.id : nil
                                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                            }
                            .onTapGesture(count: 2) {
                                playTrack(track)
                            }
                            .onTapGesture {
                                let isCmd = NSEvent.modifierFlags.contains(.command)
                                if isCmd {
                                    var ids = playerState.selectedTrackIds
                                    if ids.contains(track.id) {
                                        ids.remove(track.id)
                                    } else {
                                        ids.insert(track.id)
                                    }
                                    playerState.selectedTrackIds = ids
                                } else {
                                    playerState.selectedTrackIds = [track.id]
                                    playerState.selectedTrackId = track.id
                                }
                            }
                            .contextMenu {
                                Button("Play") { playTrack(track) }
                                Button("Play Next") { playback.enqueueNext(track) }
                                Button("Add to Queue") { playback.enqueue(track) }
                                Divider()
                                Menu("Add to Playlist") {
                                    if library.playlists.isEmpty {
                                        Text("No playlists")
                                    } else {
                                        ForEach(library.playlists) { pl in
                                            Button(pl.name) {
                                                library.addTrackToPlaylist(trackId: track.id, playlistId: pl.id)
                                            }
                                        }
                                    }
                                }
                                Divider()
                                Button("Show in Finder") {
                                    NSWorkspace.shared.selectFile(track.path, inFileViewerRootedAtPath: "")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 3 * uiScale)
                }
            }
        }
        .font(.system(size: 11 * uiScale, design: .monospaced))
        .onAppear { playerState.setVisibleTracks(filteredTracks) }
        .onChange(of: filteredTracks.map(\.id)) { _, _ in
            playerState.setVisibleTracks(filteredTracks)
        }
    }

    private func playTrack(_ track: Track) {
        playback.play(
            track: track,
            context: filteredTracks,
            title: searchText.isEmpty ? "Library" : "Search"
        )
    }
}

struct FileTableLayout {
    let width: CGFloat
    let uiScale: CGFloat

    var spacing: CGFloat { 8 * uiScale }
    var iconWidth: CGFloat { 16 * uiScale }
    var artistWidth: CGFloat { min(116 * uiScale, max(78 * uiScale, width * 0.17)) }
    var albumWidth: CGFloat { min(126 * uiScale, max(82 * uiScale, width * 0.18)) }
    var formatWidth: CGFloat { 34 * uiScale }
    var durationWidth: CGFloat { 42 * uiScale }
    var horizontalPadding: CGFloat { 10 * uiScale }
    var showArtist: Bool { width >= 500 * uiScale }
    var showAlbum: Bool { width >= 680 * uiScale }
    var showFormat: Bool { width >= 760 * uiScale }
    var rowFontSize: CGFloat { 10 * uiScale }
    var subFontSize: CGFloat { 8 * uiScale }
}

private struct FileTableHeader: View {
    let layout: FileTableLayout

    var body: some View {
        HStack(spacing: layout.spacing) {
            Text("").frame(width: layout.iconWidth)
            Text("TITLE")
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if layout.showArtist {
                Text("ARTIST").frame(width: layout.artistWidth, alignment: .leading)
            }
            if layout.showAlbum {
                Text("ALBUM").frame(width: layout.albumWidth, alignment: .leading)
            }
            if layout.showFormat {
                Text("FMT").frame(width: layout.formatWidth, alignment: .leading)
            }
            Text("TIME").frame(width: layout.durationWidth, alignment: .trailing)
        }
        .font(.system(size: 8 * layout.uiScale, weight: .medium, design: .monospaced))
        .foregroundColor(Color(white: 0.32))
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, 5 * layout.uiScale)
        .background(Color(white: 0.025))
        .overlay(Rectangle().fill(Color(white: 0.06)).frame(height: 1), alignment: .bottom)
    }
}

struct FileTreeRow: View {
    let track: Track
    let index: Int
    let isPlaying: Bool
    let isQueued: Bool
    let isSelected: Bool
    let isHovered: Bool
    let layout: FileTableLayout

    private var rowBg: Color {
        if isPlaying { return Color(red: 0.11, green: 0.13, blue: 0.12) }
        if isSelected { return Color(red: 0.14, green: 0.14, blue: 0.19) }
        if isHovered { return Color.white.opacity(0.035) }
        return index.isMultiple(of: 2) ? Color(white: 0.035) : Color(white: 0.048)
    }

    var body: some View {
        HStack(spacing: layout.spacing) {
            Text(statusGlyph)
                .foregroundColor(statusColor)
                .frame(width: layout.iconWidth)

            VStack(alignment: .leading, spacing: 1 * layout.uiScale) {
                Text(track.title ?? fileName)
                    .foregroundColor(isPlaying ? .white : Color(white: 0.68))
                    .lineLimit(1)
                if track.title != nil && track.title != fileName {
                    Text(fileName)
                        .font(.system(size: layout.subFontSize, design: .monospaced))
                        .foregroundColor(Color(white: 0.28))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if layout.showArtist {
                Text(track.artist ?? "Unknown Artist")
                    .foregroundColor(Color(white: 0.58))
                    .lineLimit(1)
                    .frame(width: layout.artistWidth, alignment: .leading)
            }

            if layout.showAlbum {
                Text(track.album ?? "Unknown Album")
                    .foregroundColor(Color(white: 0.45))
                    .lineLimit(1)
                    .frame(width: layout.albumWidth, alignment: .leading)
            }

            if layout.showFormat {
                Text(track.format.uppercased())
                    .foregroundColor(Color(white: 0.36))
                    .frame(width: layout.formatWidth, alignment: .leading)
            }

            Text(formatDuration(track.duration))
                .foregroundColor(Color(white: 0.35))
                .font(.system(size: layout.rowFontSize, design: .monospaced))
                .frame(width: layout.durationWidth, alignment: .trailing)
        }
        .font(.system(size: layout.rowFontSize, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 6 * layout.uiScale)
        .padding(.horizontal, layout.horizontalPadding)
        .background(rowBg)
    }

    private var fileName: String {
        URL(fileURLWithPath: track.path).lastPathComponent
    }

    private var statusGlyph: String {
        if isPlaying { return "\u{25B6}" }
        if isQueued { return "+" }
        return "\u{266A}"
    }

    private var statusColor: Color {
        if isPlaying { return .white }
        if isQueued { return Color(red: 0.45, green: 0.8, blue: 0.52) }
        return Color(white: 0.28)
    }

    private func formatDuration(_ d: Double) -> String {
        guard d.isFinite, d > 0 else { return "--:--" }
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }
}
