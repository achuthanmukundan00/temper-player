import Foundation
import AVFAudio
import CTemperPlayer

class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    let analyzer: RealtimeAnalyzer
    private let playerNode = AVAudioPlayerNode()
    private var decoder: DecoderBridge?
    private var avAudioFile: AVAudioFile?
    private var isAVFoundationTrack = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0

    private var currentTrackPath: String?
    private var currentFrame: Int64 = 0
    private let frameBatch: Int32 = 4096

    private let decoderFormats: Set<String> = [] // AVFoundation is used for output; Zig remains the import/analyzer path.

    private var timeTimer: Timer?
    private var seekOffset: Double = 0
    private var playbackStartTime: Date?
    private var playbackGeneration = 0
    private var finishNotified = false

    var onTrackFinished: (() -> Void)?

    init() {
        analyzer = RealtimeAnalyzer(engine: engine)
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    private func startTimeTimer() {
        timeTimer?.invalidate()
        playbackStartTime = Date()
        timeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let start = self.playbackStartTime else { return }
            self.currentTime = self.seekOffset + Date().timeIntervalSince(start)
        }
    }

    private func stopTimeTimer() {
        timeTimer?.invalidate()
        timeTimer = nil
        playbackStartTime = nil
    }

    func play(track path: String) {
        stop()

        let ext = path.lowercased().components(separatedBy: ".").last ?? ""
        currentTrackPath = path
        playbackGeneration += 1
        finishNotified = false
        analyzer.reset()
        let generation = playbackGeneration

        if decoderFormats.contains(ext) {
            playViaDecoder(path: path, generation: generation)
        } else {
            playViaAVFoundation(path: path, generation: generation)
        }

        seekOffset = 0
        currentTime = 0
        startTimeTimer()
        analyzer.installTap()
    }

    func stop() {
        playbackGeneration += 1
        finishNotified = true
        analyzer.removeTap()
        analyzer.reset()
        playerNode.stop()
        stopTimeTimer()
        decoder?.close()
        decoder = nil
        avAudioFile = nil
        currentTrackPath = nil
        currentFrame = 0
        isAVFoundationTrack = false
        isPlaying = false
        currentTime = 0
        seekOffset = 0
    }

    private func playViaDecoder(path: String, generation: Int) {
        let d = DecoderBridge()
        guard d.open(path: path) else {
            currentTrackPath = nil
            return
        }

        decoder = d
        currentFrame = 0
        isAVFoundationTrack = false

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(d.sampleRate),
            channels: AVAudioChannelCount(d.channels),
            interleaved: true
        )

        guard let format else {
            decoder = nil
            currentTrackPath = nil
            return
        }

        scheduleBuffer(format: format, generation: generation)
        playerNode.play()
        isPlaying = true
    }

    private func playViaAVFoundation(path: String, generation: Int) {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            currentTrackPath = nil
            return
        }

        avAudioFile = file
        isAVFoundationTrack = true

        playerNode.scheduleFile(file, at: nil) { [weak self] in
            self?.finishTrack(generation: generation)
        }
        playerNode.play()
        isPlaying = true
    }

    private func scheduleBuffer(format: AVAudioFormat, generation: Int) {
        guard playbackGeneration == generation else { return }
        guard let decoder else { return }

        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameBatch))!
        buf.frameLength = buf.frameCapacity

        guard let channelData = buf.floatChannelData?.pointee else {
            return
        }
        let framesRead = decoder.readFrames(
            into: channelData,
            count: frameBatch
        )

        if framesRead > 0 {
            buf.frameLength = AVAudioFrameCount(framesRead)
            currentFrame += Int64(framesRead)

            do {
                try engine.start()
            } catch {
                return
            }

            playerNode.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }
                guard self.playbackGeneration == generation else { return }
                if framesRead < self.frameBatch {
                    self.finishTrack(generation: generation)
                    return
                }
                Task { @MainActor [weak self] in
                    self?.scheduleBuffer(format: format, generation: generation)
                }
            }
        }
    }

    func pause() {
        if playerNode.isPlaying {
            seekOffset = currentTime
            stopTimeTimer()
            playerNode.pause()
            isPlaying = false
            analyzer.isFrozen = true
        }
    }

    func resume() {
        if !playerNode.isPlaying && (decoder != nil || avAudioFile != nil) {
            playbackStartTime = Date()
            timeTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self, let start = self.playbackStartTime else { return }
                self.currentTime = self.seekOffset + Date().timeIntervalSince(start)
            }
            playerNode.play()
            isPlaying = true
            analyzer.isFrozen = false
        }
    }

    func seek(to time: Double) {
        guard let path = currentTrackPath else { return }

        playbackGeneration += 1
        finishNotified = false
        let generation = playbackGeneration
        seekOffset = time
        currentTime = time
        playbackStartTime = Date()

        if isAVFoundationTrack {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
            avAudioFile = file

            let sampleRate = file.fileFormat.sampleRate
            let totalFrames = file.length
            let seekFrame = AVAudioFramePosition(time * sampleRate)
            let remainingFrames = totalFrames - seekFrame

            guard remainingFrames > 0 else { return }

            playerNode.stop()
            engine.reset()

            playerNode.scheduleSegment(
                file,
                startingFrame: max(0, seekFrame),
                frameCount: AVAudioFrameCount(remainingFrames),
                at: nil
            ) { [weak self] in
                self?.finishTrack(generation: generation)
            }

            do {
                try engine.start()
            } catch {
                return
            }

            analyzer.reinstallTap()
            if isPlaying { playerNode.play() }
        } else {
            guard let decoder else { return }
            let sampleRate = decoder.sampleRate
            let frame = Int64(time * Double(sampleRate))

            playerNode.stop()

            _ = decoder.seek(frame: frame)
            currentFrame = frame

            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(sampleRate),
                channels: AVAudioChannelCount(decoder.channels),
                interleaved: true
            )

            if let format {
                scheduleBuffer(format: format, generation: generation)
            }

            if isPlaying {
                playerNode.play()
            }
        }
    }

    func setVolume(_ volume: Float) {
        playerNode.volume = volume
    }

    var duration: Double {
        if isAVFoundationTrack, let file = avAudioFile {
            return Double(file.length) / file.fileFormat.sampleRate
        }
        guard let decoder else { return 0 }
        return decoder.durationSeconds
    }

    private func finishTrack(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.playbackGeneration == generation, !self.finishNotified else { return }

            self.finishNotified = true
            let finishedDuration = self.duration
            self.stopTimeTimer()
            self.analyzer.removeTap()
            self.playerNode.stop()
            self.decoder?.close()
            self.decoder = nil
            self.avAudioFile = nil
            self.currentTrackPath = nil
            self.currentFrame = 0
            self.isAVFoundationTrack = false
            self.isPlaying = false
            self.currentTime = max(self.currentTime, finishedDuration)
            self.seekOffset = self.currentTime
            self.onTrackFinished?()
        }
    }

    deinit {
        stop()
        engine.stop()
    }
}
