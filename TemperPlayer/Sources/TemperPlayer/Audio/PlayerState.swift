import Foundation
import Combine

class PlayerState: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var queue: [Track] = []
    @Published var queueIndex: Int?
    @Published var queueTitle = "Queue"
    @Published var visibleTracks: [Track] = []
    @Published var selectedTrackId: String? {
        didSet {
            if let id = selectedTrackId {
                if !selectedTrackIds.contains(id) {
                    selectedTrackIds = [id]
                }
            } else {
                selectedTrackIds = []
            }
        }
    }
    @Published var selectedTrackIds: Set<String> = []
    @Published var volume: Float = 1.0
    @Published var pitchShift: Float = 0
    @Published var isShuffled = false
    @Published var repeatMode: RepeatMode = .off
    private var originalQueue: [Track] = []
    // Each shuffled position refers to an occurrence, not a track ID. A track
    // may appear more than once, including on both sides of the current item.
    private var shuffledIndices: [Int] = []

    enum RepeatMode: Int { case off = 0, all, one }

    var upcomingQueue: [Track] {
        guard let queueIndex else { return queue }
        guard queueIndex + 1 < queue.count else { return [] }
        return Array(queue[(queueIndex + 1)...])
    }

    var hasPreviousTrack: Bool {
        guard let queueIndex else { return false }
        return queueIndex > 0
    }

    var hasNextTrack: Bool {
        guard let queueIndex else { return !queue.isEmpty }
        return queueIndex + 1 < queue.count
    }

    var timeString: String {
        let m = Int(currentTime) / 60
        let s = Int(currentTime) % 60
        return String(format: "%d:%02d", m, s)
    }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    var displayPath: String {
        guard let t = currentTrack else { return "no buffer loaded" }
        let url = URL(fileURLWithPath: t.path)
        let dir = url.deletingLastPathComponent().lastPathComponent
        return "\(dir)/\(url.lastPathComponent)"
    }

    func prepareToPlay(track: Track, context: [Track], title: String) {
        let resolvedContext = context.isEmpty ? [track] : context
        if let index = resolvedContext.firstIndex(where: { $0.id == track.id }) {
            queue = resolvedContext
            queueIndex = index
        } else {
            queue = [track] + resolvedContext
            queueIndex = 0
        }
        queueTitle = title
        setCurrent(track)
        if isShuffled {
            originalQueue = queue
            shuffledIndices = Array(queue.indices)
            shuffleRemaining()
        }
    }

    func enqueue(_ track: Track) {
        enqueue([track])
    }

    func enqueue(_ tracks: [Track]) {
        ensureCurrentQueue()
        if isShuffled {
            let start = originalQueue.count
            originalQueue.append(contentsOf: tracks)
            shuffledIndices.append(contentsOf: start..<originalQueue.count)
        }
        queue.append(contentsOf: tracks)
    }

    func enqueueNext(_ track: Track) {
        ensureCurrentQueue()
        let insertIndex = (queueIndex ?? -1) + 1
        if isShuffled {
            let originalIndex = queueIndex.map { shuffledIndices[$0] + 1 } ?? 0
            originalQueue.insert(track, at: originalIndex)
            shuffledIndices = shuffledIndices.map { $0 >= originalIndex ? $0 + 1 : $0 }
            shuffledIndices.insert(originalIndex, at: insertIndex)
        }
        queue.insert(track, at: insertIndex)
    }

    func toggleShuffle() {
        isShuffled.toggle()
        if isShuffled {
            originalQueue = queue
            shuffledIndices = Array(queue.indices)
            shuffleRemaining()
        } else {
            let originalIndex = queueIndex.map { shuffledIndices[$0] }
            queue = originalQueue
            queueIndex = originalIndex
            originalQueue = []
            shuffledIndices = []
        }
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    private func shuffleRemaining() {
        let start = (queueIndex ?? -1) + 1
        shuffledIndices = Array(shuffledIndices[..<start]) + shuffledIndices[start...].shuffled()
        queue = shuffledIndices.map { originalQueue[$0] }
    }

    func advanceToNext(reshuffleOnRepeat: Bool = true) -> Track? {
        ensureCurrentQueue()
        guard !queue.isEmpty else { return nil }
        if queueIndex == nil, let first = queue.first {
            queueIndex = 0
            setCurrent(first)
            return first
        }
        guard let index = queueIndex else { return nil }
        if index + 1 < queue.count {
            queueIndex = index + 1
            let next = queue[index + 1]
            setCurrent(next)
            return next
        }
        // End of queue — wrap if repeat all
        if repeatMode == .all {
            if isShuffled && reshuffleOnRepeat {
                shuffledIndices.shuffle()
                queue = shuffledIndices.map { originalQueue[$0] }
            }
            queueIndex = 0
            setCurrent(queue[0])
            return queue[0]
        }
        return nil
    }

    func retreatToPrevious() -> Track? {
        guard currentTime <= 3, let index = queueIndex, index > 0 else {
            currentTime = 0
            return currentTrack
        }
        queueIndex = index - 1
        let previous = queue[index - 1]
        setCurrent(previous)
        return previous
    }

    func playQueueItem(at index: Int) -> Track? {
        guard queue.indices.contains(index) else { return nil }
        queueIndex = index
        let track = queue[index]
        setCurrent(track)
        return track
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        if isShuffled {
            let originalIndex = shuffledIndices.remove(at: index)
            originalQueue.remove(at: originalIndex)
            shuffledIndices = shuffledIndices.map { $0 > originalIndex ? $0 - 1 : $0 }
        }
        queue.remove(at: index)

        if queue.isEmpty {
            clearCurrent()
            queueTitle = "Queue"
            return
        }

        guard let currentIndex = queueIndex else { return }
        if index < currentIndex {
            queueIndex = currentIndex - 1
        } else if index == currentIndex {
            // Removal is not a request to start a different song.
            clearCurrent()
        }
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        guard source != destination,
              queue.indices.contains(source),
              queue.indices.contains(destination) else { return }
        if isShuffled {
            // Preserve the move before/after its target in the saved order too.
            let originalSource = shuffledIndices[source]
            let originalTarget = shuffledIndices[destination]
            let targetAfterRemoval = originalTarget - (originalSource < originalTarget ? 1 : 0)
            let originalDestination = targetAfterRemoval + (source < destination ? 1 : 0)
            let originalTrack = originalQueue.remove(at: originalSource)
            originalQueue.insert(originalTrack, at: originalDestination)
            shuffledIndices = shuffledIndices.map {
                indexAfterMove($0, from: originalSource, to: originalDestination)
            }
            let movedIndex = shuffledIndices.remove(at: source)
            shuffledIndices.insert(movedIndex, at: destination)
        }
        let track = queue.remove(at: source)
        queue.insert(track, at: destination)
        if let qi = queueIndex {
            queueIndex = indexAfterMove(qi, from: source, to: destination)
        }
    }

    func clearUpcomingQueue() {
        if let currentTrack {
            queue = [currentTrack]
            queueIndex = 0
        } else {
            queue.removeAll()
            clearCurrent()
        }
        queueTitle = "Queue"
        if isShuffled {
            originalQueue = queue
            shuffledIndices = Array(queue.indices)
        }
    }

    func removeTracks(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for index in queue.indices.reversed() where ids.contains(queue[index].id) {
            removeQueueItem(at: index)
        }
        if let currentTrack, ids.contains(currentTrack.id) {
            clearCurrent()
        }
        visibleTracks.removeAll { ids.contains($0.id) }

        let remainingSelection = selectedTrackIds.subtracting(ids)
        if let selectedTrackId, ids.contains(selectedTrackId) {
            self.selectedTrackId = visibleTracks.first { remainingSelection.contains($0.id) }?.id
                ?? remainingSelection.sorted().first
        }
        selectedTrackIds = remainingSelection
    }

    /// Refresh snapshots only; absence from a library refresh is not a deletion.
    func reconcileLibraryTracks(_ tracks: [Track]) {
        let updated = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        queue = queue.map { updated[$0.id] ?? $0 }
        originalQueue = originalQueue.map { updated[$0.id] ?? $0 }
        visibleTracks = visibleTracks.map { updated[$0.id] ?? $0 }
        if let currentTrack, let refreshed = updated[currentTrack.id] {
            self.currentTrack = refreshed
        }
    }

    func finishCurrentTrack() {
        currentTime = duration
        isPlaying = false
    }

    func setVisibleTracks(_ tracks: [Track]) {
        visibleTracks = tracks
        selectedTrackIds.formIntersection(tracks.map(\.id))
        if let selectedTrackId, tracks.contains(where: { $0.id == selectedTrackId }) {
            return
        }
        if let currentTrack, tracks.contains(where: { $0.id == currentTrack.id }) {
            selectedTrackId = currentTrack.id
        } else {
            selectedTrackId = tracks.first?.id
        }
    }

    func selectVisibleTrack(offset: Int) {
        guard !visibleTracks.isEmpty else { return }
        let currentIndex = selectedTrackId.flatMap { id in
            visibleTracks.firstIndex { $0.id == id }
        } ?? 0
        let nextIndex = max(0, min(visibleTracks.count - 1, currentIndex + offset))
        selectedTrackId = visibleTracks[nextIndex].id
        selectedTrackIds = [visibleTracks[nextIndex].id]
    }

    var selectedVisibleTrack: Track? {
        guard let selectedTrackId else { return visibleTracks.first }
        return visibleTracks.first { $0.id == selectedTrackId } ?? visibleTracks.first
    }

    private func setCurrent(_ track: Track) {
        currentTrack = track
        duration = track.duration
        currentTime = 0
    }

    private func clearCurrent() {
        currentTrack = nil
        queueIndex = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func indexAfterMove(_ index: Int, from source: Int, to destination: Int) -> Int {
        if index == source { return destination }
        if source < index && destination >= index { return index - 1 }
        if source > index && destination <= index { return index + 1 }
        return index
    }

    private func ensureCurrentQueue() {
        guard queue.isEmpty, let currentTrack else { return }
        queue = [currentTrack]
        queueIndex = 0
        if isShuffled {
            originalQueue = queue
            shuffledIndices = [0]
        }
    }
}
