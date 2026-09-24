import XCTest
@testable import TemperPlayer

final class LibraryQueryTests: XCTestCase {
    private func track(_ id: String, title: String? = nil, artist: String? = nil, album: String? = nil,
                       disc: Int? = nil, number: Int? = nil) -> Track {
        Track(id: id, path: "/Music/\(id).flac", title: title, artist: artist, album: album,
              trackNo: number, discNo: disc, duration: 60, format: "flac", sampleRate: 48000,
              bitDepth: 24, channels: 2, bitrate: 1000, fileSize: 1024,
              dateAdded: Date(timeIntervalSince1970: 100), playCount: 0)
    }

    func testSearchUsesAllTermsAcrossFieldsAndIgnoresWhitespaceCaseAndDiacritics() {
        let a = track("a", title: "Café Moon", artist: "Björk", album: "Night")
        let b = track("b", title: "Moon", artist: "Other")
        XCTAssertEqual(LibraryQuery.filter([a, b], search: "  CAFE  bjork \n").map(\.id), ["a"])
        XCTAssertEqual(LibraryQuery.filter([a, b], search: "  \n ").map(\.id), ["a", "b"])
        XCTAssertEqual(LibraryQuery.filter([a, b], search: "a.flac").map(\.id), ["a"])
        XCTAssertTrue(LibraryQuery.filter([a, b], search: "moon missing").isEmpty)
    }

    func testAlbumSortUsesDiscAndTrackNumbersWithMissingDiscEquivalentToOne() {
        let laterDisc = track("later", album: "Album", disc: 2, number: 1)
        let second = track("second", album: "Album", number: 2)
        let first = track("first", album: "Album", disc: 1, number: 1)
        XCTAssertEqual(LibraryQuery.sorted([laterDisc, second, first], by: .album).map(\.id), ["first", "second", "later"])
        XCTAssertEqual(LibraryQuery.sorted([laterDisc, second, first], by: .album, ascending: false).map(\.id), ["later", "second", "first"])
    }

    func testNaturalTitleOrderingAndDeterministicTies() {
        let tracks = [track("b", title: "Song 10"), track("c", title: "Song 2"), track("a", title: "Song 2")]
        XCTAssertEqual(LibraryQuery.sorted(tracks, by: .title).map(\.id), ["a", "c", "b"])
        XCTAssertEqual(LibraryQuery.sorted(tracks, by: .dateAdded).map(\.id), ["a", "c", "b"])
    }

    func testRecentlyPlayedPlacesNeverPlayedLast() {
        var recent = track("recent")
        recent.lastPlayed = Date()
        XCTAssertEqual(LibraryQuery.sorted([track("never"), recent], by: .lastPlayed).map(\.id), ["recent", "never"])
    }

    func testSelectionRangeAndCommandToggle() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(LibraryQuery.selection(clicked: "d", visibleIDs: ids, selected: ["b"], anchor: "b", command: false, shift: true), ["b", "c", "d"])
        XCTAssertEqual(LibraryQuery.selection(clicked: "b", visibleIDs: ids, selected: ["a"], anchor: "d", command: true, shift: true), Set(ids))
        XCTAssertEqual(LibraryQuery.selection(clicked: "a", visibleIDs: ids, selected: ["a", "b"], anchor: "a", command: true, shift: false), ["b"])
        XCTAssertEqual(LibraryQuery.selection(clicked: "c", visibleIDs: ids, selected: ["a"], anchor: "missing", command: false, shift: true), ["c"])
    }

    func testDisplayFallbackAndInvalidDurationAreSafe() {
        var a = track("filename", title: "  ")
        XCTAssertEqual(a.displayTitle, "filename")
        a.duration = .nan
        XCTAssertEqual(a.formattedDuration, "--:--")
        a.duration = .infinity
        XCTAssertEqual(a.formattedDuration, "--:--")
        a.duration = 125
        XCTAssertEqual(a.formattedDuration, "2:05")
    }
}
