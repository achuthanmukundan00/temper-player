import Foundation
import Combine

@MainActor
final class PlaybackController: ObservableObject {
    private let audioManager: AudioManager
    private let library: Database
    private let playerState: PlayerState
    @Published var playbackError: String?
    private var failedTrackIDs: Set<String> = []
    private var playbackGeneration = 0

    init(audioManager: AudioManager, library: Database, playerState: PlayerState) {
        self.audioManager = audioManager
        self.library = library
        self.playerState = playerState

        observeCurrentPlayback()
    }

    func play(track: Track, context: [Track]? = nil, title: String = "Queue") {
        resetPlaybackAttempt()
        let resolvedContext = context ?? [track]
        playerState.prepareToPlay(track: track, context: resolvedContext, title: title)
        startPreparedTrack(track)
    }

    func playQueueItem(at index: Int) {
        guard let track = playerState.playQueueItem(at: index) else { return }
        resetPlaybackAttempt()
        startPreparedTrack(track)
    }

    func togglePlayPause() {
        if playerState.isPlaying {
            pause()
        } else if playerState.currentTrack != nil {
            resume()
        } else if let queued = playerState.advanceToNext() {
            resetPlaybackAttempt()
            startPreparedTrack(queued)
        }
    }

    func pause() {
        playbackGeneration += 1
        audioManager.pause()
        playerState.isPlaying = false
    }

    func resume() {
        guard !playerState.isPlaying, let track = playerState.currentTrack else { return }
        resetPlaybackAttempt()
        observeCurrentPlayback()
        let atEnd = playerState.duration > 0 && playerState.currentTime >= playerState.duration
        if !atEnd && audioManager.resume() {
            playerState.isPlaying = true
        } else {
            // Completed/failed playback has no loaded file to resume.
            playerState.currentTime = 0
            startPreparedTrack(track)
        }
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, playerState.duration))
        playerState.currentTime = clamped
        observeCurrentPlayback()
        audioManager.seek(to: clamped)
    }

    func seek(by delta: Double) {
        seek(to: playerState.currentTime + delta)
    }

    func previous() {
        guard let track = playerState.retreatToPrevious() else { return }
        resetPlaybackAttempt()
        startPreparedTrack(track)
    }

    func next() {
        guard let track = playerState.advanceToNext() else { return }
        resetPlaybackAttempt()
        startPreparedTrack(track)
    }

    func enqueue(_ track: Track) {
        playerState.enqueue(track)
    }

    func enqueue(_ tracks: [Track]) {
        playerState.enqueue(tracks)
    }

    func enqueueNext(_ track: Track) {
        playerState.enqueueNext(track)
    }

    func removeQueueItem(at index: Int) {
        guard playerState.queue.indices.contains(index) else { return }
        if playerState.queueIndex == index {
            stopAudio()
            resetPlaybackAttempt()
        }
        playerState.removeQueueItem(at: index)
    }

    @discardableResult
    func removeLibraryTracks(ids: Set<String>) -> Bool {
        guard library.deleteTracks(ids: ids) else { return false }
        if let current = playerState.currentTrack, ids.contains(current.id) {
            stopAudio()
            resetPlaybackAttempt()
        }
        failedTrackIDs.subtract(ids)
        playerState.removeTracks(ids: ids)
        return true
    }

    func reconcileLibraryTracks() {
        playerState.reconcileLibraryTracks(library.tracks)
    }

    func clearUpcomingQueue() {
        playerState.clearUpcomingQueue()
    }

    func moveQueueItem(from source: Int, to destination: Int) {
        playerState.moveQueueItem(from: source, to: destination)
    }

    func setPitchShift(_ cents: Float) {
        audioManager.setPitchShift(cents)
    }

    func setVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        playerState.volume = clamped
        audioManager.setVolume(clamped)
    }

    func toggleShuffle() {
        playerState.toggleShuffle()
    }

    func cycleRepeatMode() {
        playerState.cycleRepeatMode()
    }

    private func playNextAfterFinish(reason: AudioManager.TrackEndReason) {
        guard let track = playerState.currentTrack else { return }
        if reason == .failed {
            reportPlaybackFailure(track)
        } else {
            // Keep failures across failed starts AND asynchronous decoding failures.
            // Only a completed track or an explicit user retry starts a fresh pass.
            failedTrackIDs.removeAll()
        }
        if reason == .completed, playerState.repeatMode == .one {
            startPreparedTrack(track)
            return
        }
        guard let next = playerState.advanceToNext(reshuffleOnRepeat: reason == .completed) else {
            if reason == .completed {
                playerState.finishCurrentTrack()
            } else {
                stopAudio()
                playerState.currentTime = 0
            }
            return
        }
        startPreparedTrack(next)
    }

    private func startPreparedTrack(_ track: Track) {
        var candidate: Track? = track
        var remaining = max(1, playerState.queue.count)

        // Visit at most one queue pass. Duplicate occurrences of a failed file
        // are skipped, not treated as the end of the search for a playable file.
        while let current = candidate, remaining > 0 {
            remaining -= 1
            if !failedTrackIDs.contains(current.id) {
                observeCurrentPlayback()
                if audioManager.play(track: current.path) {
                    audioManager.setVolume(playerState.volume)
                    audioManager.setPitchShift(playerState.pitchShift)
                    playerState.duration = current.duration > 0 ? current.duration : audioManager.duration
                    playerState.isPlaying = true
                    library.recordPlayback(trackId: current.id)
                    return
                }
                reportPlaybackFailure(current)
            }
            guard remaining > 0 else { break }
            // Re-shuffling during a failure scan can revisit failures and miss
            // playable occurrences before the bounded pass is exhausted.
            candidate = playerState.advanceToNext(reshuffleOnRepeat: false)
        }

        stopAudio()
        playerState.currentTime = 0
    }

    private func reportPlaybackFailure(_ track: Track) {
        failedTrackIDs.insert(track.id)
        if FileManager.default.fileExists(atPath: track.path) {
            let name = track.title ?? URL(fileURLWithPath: track.path).lastPathComponent
            playbackError = "Unable to play \"\(name)\". The audio file could not be read."
        } else {
            playbackError = "File not found: \(track.path)"
        }
    }

    private func resetPlaybackAttempt() {
        failedTrackIDs.removeAll()
        playbackError = nil
    }

    private func stopAudio() {
        playbackGeneration += 1
        audioManager.stop()
        playerState.isPlaying = false
    }

    private func observeCurrentPlayback() {
        playbackGeneration += 1
        let generation = playbackGeneration
        audioManager.onTrackFinished = { [weak self] reason in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation else { return }
                self.playNextAfterFinish(reason: reason)
            }
        }
    }
}
