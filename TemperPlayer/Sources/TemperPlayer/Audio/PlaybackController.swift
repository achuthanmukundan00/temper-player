import Foundation

@MainActor
final class PlaybackController: ObservableObject {
    private let audioManager: AudioManager
    private let library: Database
    private let playerState: PlayerState

    init(audioManager: AudioManager, library: Database, playerState: PlayerState) {
        self.audioManager = audioManager
        self.library = library
        self.playerState = playerState

        audioManager.onTrackFinished = { [weak self] in
            Task { @MainActor in
                self?.playNextAfterFinish()
            }
        }
    }

    func play(track: Track, context: [Track]? = nil, title: String = "Queue") {
        let resolvedContext = context ?? [track]
        playerState.prepareToPlay(track: track, context: resolvedContext, title: title)
        startPreparedTrack(track)
    }

    func playQueueItem(at index: Int) {
        guard let track = playerState.playQueueItem(at: index) else { return }
        startPreparedTrack(track)
    }

    func togglePlayPause() {
        if playerState.isPlaying {
            pause()
        } else if playerState.currentTrack != nil {
            resume()
        } else if let queued = playerState.advanceToNext() {
            startPreparedTrack(queued)
        }
    }

    func pause() {
        audioManager.pause()
        playerState.isPlaying = false
    }

    func resume() {
        audioManager.resume()
        playerState.isPlaying = true
    }

    func seek(to time: Double) {
        let clamped = max(0, min(time, playerState.duration))
        playerState.currentTime = clamped
        audioManager.seek(to: clamped)
    }

    func seek(by delta: Double) {
        seek(to: playerState.currentTime + delta)
    }

    func previous() {
        guard let track = playerState.retreatToPrevious() else { return }
        startPreparedTrack(track)
    }

    func next() {
        guard let track = playerState.advanceToNext() else { return }
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
        let wasCurrent = playerState.queueIndex == index
        playerState.removeQueueItem(at: index)
        if wasCurrent, let current = playerState.currentTrack {
            startPreparedTrack(current)
        }
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

    private func playNextAfterFinish() {
        if playerState.repeatMode == .one, let track = playerState.currentTrack {
            startPreparedTrack(track)
            return
        }
        guard let next = playerState.advanceToNext() else {
            playerState.finishCurrentTrack()
            return
        }
        startPreparedTrack(next)
    }

    private func startPreparedTrack(_ track: Track) {
        audioManager.play(track: track.path)
        audioManager.setVolume(playerState.volume)
        audioManager.setPitchShift(playerState.pitchShift)
        playerState.duration = track.duration > 0 ? track.duration : audioManager.duration
        playerState.isPlaying = true
        library.recordPlayback(trackId: track.id)
    }
}
