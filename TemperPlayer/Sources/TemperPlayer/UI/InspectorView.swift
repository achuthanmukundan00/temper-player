import SwiftUI
import CTemperPlayer

struct InspectorView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale
    @ObservedObject private var importService = ImportService.shared
    let hoveredTrackId: String?
    @State private var editTarget: EditTarget?
    @State private var editValue = ""
    @State private var showArtworkPicker = false
    @State private var draggedAbsoluteIndex: Int?
    @State private var batchTitle = ""
    @State private var batchArtist = ""
    @State private var batchAlbum = ""

    enum EditTarget: String {
        case title, artist, album
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10 * uiScale) {
                    nowSection

                    if let track = displayedTrack {
                        MetadataInfoView(track: track, uiScale: uiScale)
                        StreamInfoView(track: track, uiScale: uiScale)
                        SignalInfoView(track: track, uiScale: uiScale)
                    } else if playerState.selectedTrackIds.count > 1 {
                        batchEditSection
                    } else {
                        Text("no buffer loaded")
                            .font(.system(size: 9 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.25))
                    }

                    queueSection
                }
                .padding(12 * uiScale)
                .padding(.bottom, 34 * uiScale)
            }

            Spacer(minLength: 0)
        }
        .font(.system(size: 10 * uiScale, design: .monospaced))
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 8 * uiScale) {
            let multiCount = playerState.selectedTrackIds.count
            if multiCount > 1 {
                SectionHeader(title: "\(multiCount) SELECTED", uiScale: uiScale)
                HStack(spacing: -10 * uiScale) {
                    ForEach(0..<min(multiCount, 4), id: \.self) { _ in
                        Rectangle()
                            .fill(Color(white: 0.1))
                            .frame(width: 36 * uiScale, height: 36 * uiScale)
                            .overlay(Rectangle().stroke(Color(white: 0.15), lineWidth: 0.5))
                    }
                    if multiCount > 4 {
                        Text("+\(multiCount - 4)")
                            .font(.system(size: 8 * uiScale, design: .monospaced))
                            .foregroundColor(Color(white: 0.3))
                    }
                }
                Text("\(multiCount) tracks selected")
                    .font(.system(size: 9 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
            } else if let track = displayedTrack {
                SectionHeader(title: "NOW", uiScale: uiScale)
                HStack(alignment: .top, spacing: 8 * uiScale) {
                    artwork(for: track)
                VStack(alignment: .leading, spacing: 3 * uiScale) {
                    editableText(
                        value: track.title ?? URL(fileURLWithPath: track.path).deletingPathExtension().lastPathComponent,
                        field: .title,
                        font: .system(size: 12 * uiScale, weight: .semibold, design: .monospaced),
                        color: .white
                    )
                    editableText(
                        value: track.artist ?? "Unknown Artist",
                        field: .artist,
                        font: .system(size: 10 * uiScale, design: .monospaced),
                        color: Color(white: 0.5)
                    )
                    editableText(
                        value: track.album ?? "Unknown Album",
                        field: .album,
                        font: .system(size: 10 * uiScale, design: .monospaced),
                        color: Color(white: 0.35)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

                Text(track.path)
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.32))
                    .lineLimit(3)
            } else {
                SectionHeader(title: "NOW", uiScale: uiScale)
                Text("idle")
                    .foregroundColor(Color(white: 0.25))
            }
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 7 * uiScale) {
            HStack {
                SectionHeader(title: playerState.queueTitle.uppercased(), uiScale: uiScale)
                Spacer()
                if !playerState.upcomingQueue.isEmpty {
                    Button("CLEAR") { playback.clearUpcomingQueue() }
                        .buttonStyle(.plain)
                        .font(.system(size: 8 * uiScale, design: .monospaced))
                        .foregroundColor(Color(white: 0.36))
                }
            }

            if let current = playerState.currentTrack {
                QueueRow(
                    prefix: "\u{25B6}",
                    title: current.title ?? URL(fileURLWithPath: current.path).lastPathComponent,
                    detail: current.artist ?? current.format.uppercased(),
                    isCurrent: true,
                    uiScale: uiScale
                )
            }

            let upcoming = Array(playerState.upcomingQueue.prefix(8).enumerated())
            ForEach(upcoming, id: \.offset) { offset, track in
                let absoluteIndex = (playerState.queueIndex ?? -1) + offset + 1
                QueueRow(
                    prefix: String(format: "%02d", offset + 1),
                    title: track.title ?? URL(fileURLWithPath: track.path).lastPathComponent,
                    detail: track.artist ?? track.format.uppercased(),
                    isCurrent: false,
                    uiScale: uiScale
                )
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    playback.playQueueItem(at: absoluteIndex)
                }
                .onDrag {
                    self.draggedAbsoluteIndex = absoluteIndex
                    return NSItemProvider(object: String(absoluteIndex) as NSString)
                }
                .onDrop(of: [.text], isTargeted: nil) { providers in
                    defer { self.draggedAbsoluteIndex = nil }
                    guard let dragged = self.draggedAbsoluteIndex,
                          dragged != absoluteIndex else { return false }
                    playback.moveQueueItem(from: dragged, to: absoluteIndex)
                    return true
                }
                .contextMenu {
                    Button("Play") {
                        playback.playQueueItem(at: absoluteIndex)
                    }
                    Button("Remove") {
                        playback.removeQueueItem(at: absoluteIndex)
                    }
                }
            }

            if playerState.upcomingQueue.count > 8 {
                Text("+\(playerState.upcomingQueue.count - 8) more")
                    .foregroundColor(Color(white: 0.25))
            } else if playerState.currentTrack == nil {
                Text("empty")
                    .foregroundColor(Color(white: 0.25))
            }
        }
    }

    @ViewBuilder
    private func artwork(for track: Track) -> some View {
        let artworkSize: CGFloat = 52 * uiScale
        ZStack(alignment: .bottomTrailing) {
            if let data = importService.artwork(for: track.id), let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: artworkSize, height: artworkSize)
                    .clipped()
                    .overlay(Rectangle().stroke(Color(white: 0.12), lineWidth: 1))
            } else {
                Rectangle()
                    .fill(Color(white: 0.08))
                    .frame(width: artworkSize, height: artworkSize)
                    .overlay(Rectangle().stroke(Color(white: 0.12), lineWidth: 1))
            }

            Text("+")
                .font(.system(size: 11 * uiScale, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
                .frame(width: 18 * uiScale, height: 18 * uiScale)
                .background(Color(white: 0.25))
                .clipShape(Circle())
                .onTapGesture { pickArtwork(for: track.id) }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            handleArtworkDrop(providers: providers, trackId: track.id)
        }
    }

    private func editableText(value: String, field: EditTarget, font: Font, color: Color) -> some View {
        Group {
            if editTarget == field {
                TextField("", text: $editValue)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundColor(.white)
                    .onSubmit { commitEdit(field: field) }
                    .onExitCommand { editTarget = nil }
            } else {
                Text(value)
                    .font(font)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .onTapGesture {
                        editTarget = field
                        editValue = value
                    }
            }
        }
    }

    private func commitEdit(field: EditTarget) {
        guard let track = displayedTrack else {
            editTarget = nil
            return
        }
        let trimmed = editValue.trimmingCharacters(in: .whitespaces)
        let title = field == .title ? (trimmed.isEmpty ? nil : trimmed) : track.title
        let artist = field == .artist ? (trimmed.isEmpty ? nil : trimmed) : track.artist
        let album = field == .album ? (trimmed.isEmpty ? nil : trimmed) : track.album
        library.updateTrackMetadata(id: track.id, title: title, artist: artist, album: album)
        editTarget = nil
    }

    private func pickArtwork(for trackId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importService.updateArtwork(trackId: trackId, from: url)
    }

    private func handleArtworkDrop(providers: [NSItemProvider], trackId: String) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
            guard let url = item as? URL else { return }
            DispatchQueue.main.async {
                ImportService.shared.updateArtwork(trackId: trackId, from: url)
            }
        }
        return true
    }

    private var batchEditSection: some View {
        let ids = Array(playerState.selectedTrackIds)
        return VStack(alignment: .leading, spacing: 8 * uiScale) {
            SectionHeader(title: "BATCH (\(ids.count) tracks)", uiScale: uiScale)

            VStack(alignment: .leading, spacing: 4 * uiScale) {
                Text("title").foregroundColor(Color(white: 0.36))
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                TextField("", text: $batchTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundColor(.white)

                Text("artist").foregroundColor(Color(white: 0.36))
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                TextField("", text: $batchArtist)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundColor(.white)

                Text("album").foregroundColor(Color(white: 0.36))
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                TextField("", text: $batchAlbum)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundColor(.white)
            }

            HStack(spacing: 8 * uiScale) {
                Button("APPLY") {
                    let t = batchTitle.trimmingCharacters(in: .whitespaces)
                    let a = batchArtist.trimmingCharacters(in: .whitespaces)
                    let al = batchAlbum.trimmingCharacters(in: .whitespaces)
                    library.batchUpdateTrackMetadata(
                        ids: ids,
                        title: t.isEmpty ? nil : t,
                        artist: a.isEmpty ? nil : a,
                        album: al.isEmpty ? nil : al
                    )
                    batchTitle = ""; batchArtist = ""; batchAlbum = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 9 * uiScale, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.45, green: 0.8, blue: 0.52))
                .padding(.horizontal, 8 * uiScale)
                .padding(.vertical, 3 * uiScale)
                .background(Color(white: 0.08))
                .cornerRadius(3)

                Button("CLEAR") {
                    batchTitle = ""; batchArtist = ""; batchAlbum = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 8 * uiScale, design: .monospaced))
                .foregroundColor(Color(white: 0.36))
            }

            // Batch artwork
            SectionHeader(title: "ARTWORK", uiScale: uiScale)
            ZStack {
                Rectangle()
                    .fill(Color(white: 0.06))
                    .frame(height: 40 * uiScale)
                    .overlay(Rectangle().stroke(Color(white: 0.12), lineWidth: 1))
                Text("drop image or +")
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.3))
            }
            .onTapGesture {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.allowedContentTypes = [.image]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                importService.batchUpdateArtwork(trackIds: ids, from: url)
            }
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                _ = provider.loadObject(ofClass: NSURL.self) { item, _ in
                    guard let url = item as? URL else { return }
                    DispatchQueue.main.async {
                        ImportService.shared.batchUpdateArtwork(trackIds: ids, from: url)
                    }
                }
                return true
            }
        }
    }

    private var displayedTrack: Track? {
        if playerState.selectedTrackIds.count > 1 { return nil }
        if playerState.isPlaying, let ct = playerState.currentTrack { return ct }
        if let id = hoveredTrackId, let t = library.tracks.first(where: { $0.id == id }) { return t }
        if let id = playerState.selectedTrackId, let t = library.tracks.first(where: { $0.id == id }) { return t }
        return playerState.currentTrack
    }
}

struct SectionHeader: View {
    let title: String
    let uiScale: CGFloat
    var body: some View {
        Text(title)
            .font(.system(size: 8 * uiScale, weight: .medium, design: .monospaced))
            .foregroundColor(Color(white: 0.36))
            .tracking(1.4)
    }
}

private struct MetadataInfoView: View {
    let track: Track
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            SectionHeader(title: "METADATA", uiScale: uiScale)
            KeyValueRow(key: "artist", value: track.artist ?? "Unknown Artist", uiScale: uiScale)
            KeyValueRow(key: "album", value: track.album ?? "Unknown Album", uiScale: uiScale)
            if let albumArtist = track.albumArtist {
                KeyValueRow(key: "album artist", value: albumArtist, uiScale: uiScale)
            }
            if let trackNo = track.trackNo, trackNo > 0 {
                KeyValueRow(key: "track", value: "\(trackNo)", uiScale: uiScale)
            }
            if let discNo = track.discNo, discNo > 0 {
                KeyValueRow(key: "disc", value: "\(discNo)", uiScale: uiScale)
            }
            if let year = track.year, year > 0 {
                KeyValueRow(key: "year", value: "\(year)", uiScale: uiScale)
            }
            if let genre = track.genre {
                KeyValueRow(key: "genre", value: genre, uiScale: uiScale)
            }
            KeyValueRow(key: "plays", value: "\(track.playCount)", uiScale: uiScale)
            KeyValueRow(key: "size", value: ByteCountFormatter.string(fromByteCount: Int64(track.fileSize), countStyle: .file), uiScale: uiScale)
        }
    }
}

struct StreamInfoView: View {
    let track: Track
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            SectionHeader(title: "STREAM", uiScale: uiScale)
            KeyValueRow(key: "format", value: track.format.uppercased(), color: .white, uiScale: uiScale)
            KeyValueRow(key: "sample rate", value: formatSampleRate(track.sampleRate), color: .white, uiScale: uiScale)
            KeyValueRow(key: "bit depth", value: track.bitDepth > 0 ? "\(track.bitDepth)" : "-", color: .white, uiScale: uiScale)
            KeyValueRow(key: "channels", value: track.channels > 0 ? "\(track.channels)" : "-", color: .white, uiScale: uiScale)
            KeyValueRow(key: "duration", value: durationString(track.duration), color: .white, uiScale: uiScale)
            if track.bitrate > 0 {
                KeyValueRow(key: "bitrate", value: "\(track.bitrate / 1000) kbps", color: .white, uiScale: uiScale)
            }
        }
    }

    private func formatSampleRate(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "-"
    }

    private func durationString(_ d: Double) -> String {
        guard d.isFinite, d > 0 else { return "--:--" }
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d.%d", m, s, Int(d * 10) % 10)
    }
}

private struct SignalInfoView: View {
    let track: Track
    let uiScale: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * uiScale) {
            SectionHeader(title: "SIGNAL", uiScale: uiScale)
            if let l = track.lufs {
                KeyValueRow(key: "loudness", value: String(format: "%.1f LUFS", l), color: .white, uiScale: uiScale)
            }
            if let tp = track.truePeak {
                KeyValueRow(key: "true peak", value: String(format: "%.1f dBTP", tp), color: .white, uiScale: uiScale)
            }
            if let dr = track.dynamicRange {
                KeyValueRow(key: "dynamic", value: String(format: "%.1f dB", dr), color: .white, uiScale: uiScale)
            }
            if let pc = track.phaseCorrelation {
                KeyValueRow(key: "phase", value: "\(phaseLabel(pc)) (\(String(format: "%+.2f", pc)))", color: phaseColor(pc), uiScale: uiScale)
            }
            if let dc = track.dcOffset {
                KeyValueRow(key: "dc offset", value: String(format: "%+.3f%%", dc), color: abs(dc) < 0.01 ? Color(white: 0.65) : Color(red: 0.9, green: 0.7, blue: 0.3), uiScale: uiScale)
            }
        }
    }

    private func phaseLabel(_ value: Double) -> String {
        if value > 0.5 { return "ok" }
        if value > 0 { return "warn" }
        return "bad"
    }

    private func phaseColor(_ value: Double) -> Color {
        if value > 0.5 { return Color(red: 0.45, green: 0.8, blue: 0.52) }
        if value > 0 { return Color(red: 0.9, green: 0.7, blue: 0.3) }
        return Color(red: 0.9, green: 0.32, blue: 0.32)
    }
}

private struct QueueRow: View {
    let prefix: String
    let title: String
    let detail: String
    let isCurrent: Bool
    let uiScale: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7 * uiScale) {
            Text(prefix)
                .foregroundColor(isCurrent ? .white : Color(white: 0.32))
                .frame(width: 22 * uiScale, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1 * uiScale) {
                Text(title)
                    .foregroundColor(isCurrent ? .white : Color(white: 0.65))
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 8 * uiScale, design: .monospaced))
                    .foregroundColor(Color(white: 0.28))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2 * uiScale)
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var color: Color = Color(white: 0.68)
    let uiScale: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * uiScale) {
            Text(key)
                .foregroundColor(Color(white: 0.36))
                .frame(width: 68 * uiScale, alignment: .trailing)
            Text(value)
                .foregroundColor(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 8 * uiScale, design: .monospaced))
    }
}
