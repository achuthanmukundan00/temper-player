import Foundation

extension Track {
    var displayTitle: String {
        guard let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        return title
    }

    var formattedDuration: String {
        guard duration.isFinite, duration > 0 else { return "--:--" }
        let seconds = Int(min(duration, Double(Int32.max)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var folderPath: String { URL(fileURLWithPath: path).deletingLastPathComponent().path }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case dateAdded = "Recently Added"
    case title = "Title"
    case artist = "Artist"
    case album = "Album / Track"
    case duration = "Duration"
    case lastPlayed = "Recently Played"
    var id: String { rawValue }
}

enum LibraryQuery {
    static func filter(_ tracks: [Track], search: String) -> [Track] {
        let terms = search.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return tracks }
        return tracks.filter { track in
            let fields = [track.displayTitle, track.artist ?? "", track.album ?? "",
                          track.albumArtist ?? "", track.genre ?? "", track.path, track.format]
            return terms.allSatisfy { term in
                fields.contains { $0.localizedStandardContains(term) }
            }
        }
    }

    static func sorted(_ tracks: [Track], by sort: LibrarySort, ascending: Bool = true) -> [Track] {
        tracks.sorted { left, right in
            let lhs = ascending ? left : right
            let rhs = ascending ? right : left
            switch sort {
            case .dateAdded:
                if lhs.dateAdded != rhs.dateAdded { return lhs.dateAdded > rhs.dateAdded }
            case .title: break
            case .artist:
                let comparison = (lhs.artist ?? "Unknown Artist").localizedStandardCompare(rhs.artist ?? "Unknown Artist")
                if comparison != .orderedSame { return comparison == .orderedAscending }
            case .album:
                let artist = (lhs.albumArtist ?? lhs.artist ?? "").localizedStandardCompare(rhs.albumArtist ?? rhs.artist ?? "")
                if artist != .orderedSame { return artist == .orderedAscending }
                let album = (lhs.album ?? "Unknown Album").localizedStandardCompare(rhs.album ?? "Unknown Album")
                if album != .orderedSame { return album == .orderedAscending }
                if (lhs.discNo ?? 1) != (rhs.discNo ?? 1) { return (lhs.discNo ?? 1) < (rhs.discNo ?? 1) }
                if (lhs.trackNo ?? Int.max) != (rhs.trackNo ?? Int.max) { return (lhs.trackNo ?? Int.max) < (rhs.trackNo ?? Int.max) }
            case .duration:
                let l = lhs.duration.isFinite ? lhs.duration : 0
                let r = rhs.duration.isFinite ? rhs.duration : 0
                if l != r { return l < r }
            case .lastPlayed:
                if lhs.lastPlayed != rhs.lastPlayed { return (lhs.lastPlayed ?? .distantPast) > (rhs.lastPlayed ?? .distantPast) }
            }
            let title = lhs.displayTitle.localizedStandardCompare(rhs.displayTitle)
            return title == .orderedSame ? lhs.id < rhs.id : title == .orderedAscending
        }
    }

    static func selection(clicked id: String, visibleIDs: [String], selected: Set<String>, anchor: String?, command: Bool, shift: Bool) -> Set<String> {
        if shift, let anchor, let start = visibleIDs.firstIndex(of: anchor), let end = visibleIDs.firstIndex(of: id) {
            let range = Set(visibleIDs[min(start, end)...max(start, end)])
            return command ? selected.union(range) : range
        }
        if command {
            var result = selected
            if !result.insert(id).inserted { result.remove(id) }
            return result
        }
        return [id]
    }
}
