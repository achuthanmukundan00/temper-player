import Foundation
import AVFAudio
import CTemperPlayer

class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var decoder: DecoderBridge?
    private var avAudioFile: AVAudioFile?
    private var isAVFoundationTrack = false
    @Published var isPlaying = false
    @Published var currentTime: Double = 0

    private var currentTrackPath: String?
    private var currentFrame: Int64 = 0
    private let scheduleQueue = DispatchQueue(label: "com.temperplayer.audio")
    private let frameBatch: Int32 = 8192

    private let decoderFormats: Set<String> = ["flac", "wav"]

    private var timeTimer: Timer?
    private var seekOffset: Double = 0
    private var playbackStartTime: Date?

    init() {
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

        if decoderFormats.contains(ext) {
            playViaDecoder(path: path)
        } else {
            playViaAVFoundation(path: path)
        }

        seekOffset = 0
        currentTime = 0
        startTimeTimer()
    }

    private func playViaDecoder(path: String) {
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

        scheduleQueue.async { [weak self] in
            self?.scheduleBuffer(format: format)
        }

        playerNode.play()
        isPlaying = true
    }

    private func playViaAVFoundation(path: String) {
        let url = URL(fileURLWithPath: path)
        guard let file = try? AVAudioFile(forReading: url) else {
            currentTrackPath = nil
            return
        }

        avAudioFile = file
        isAVFoundationTrack = true

        playerNode.scheduleFile(file, at: nil)
        playerNode.play()
        isPlaying = true
    }

    private func scheduleBuffer(format: AVAudioFormat) {
        guard let decoder else { return }

        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameBatch))!
        buf.frameLength = buf.frameCapacity

        let framesRead = decoder.readFrames(
            into: buf.floatChannelData!.pointee,
            count: frameBatch
        )

        if framesRead > 0 {
            buf.frameLength = AVAudioFrameCount(framesRead)
            currentFrame += Int64(framesRead)

            playerNode.scheduleBuffer(buf) { [weak self] in
                guard let self else { return }

                if framesRead < self.frameBatch {
                    self.playerNode.stop()
                    self.isPlaying = false
                    return
                }

                self.scheduleQueue.async {
                    self.scheduleBuffer(format: format)
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
        }
    }

    func stop() {
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

    func seek(to time: Double) {
        guard let path = currentTrackPath else { return }

        seekOffset = time
        currentTime = time
        playbackStartTime = Date()

        if isAVFoundationTrack {
            guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return }
            avAudioFile = file
            playerNode.stop()

            let framePosition = AVAudioFramePosition(time * file.fileFormat.sampleRate)
            file.framePosition = max(0, framePosition)

            playerNode.scheduleFile(file, at: nil)
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
                scheduleQueue.async { [weak self] in
                    self?.scheduleBuffer(format: format)
                }
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

    deinit {
        stop()
        engine.stop()
    }
}
