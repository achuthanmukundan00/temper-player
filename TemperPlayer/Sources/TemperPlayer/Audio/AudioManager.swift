import Foundation
import AVFAudio
import CTemperPlayer

class AudioManager: ObservableObject {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var decoder: DecoderBridge?
    @Published var isPlaying = false

    private var currentTrackPath: String?
    private var currentFrame: Int64 = 0
    private let scheduleQueue = DispatchQueue(label: "com.temperplayer.audio")
    private let frameBatch: Int32 = 8192

    override init() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: nil)
        try? engine.start()
    }

    func play(track path: String) {
        stop()

        let d = DecoderBridge()
        guard d.open(path: path) else { return }

        decoder = d
        currentTrackPath = path
        currentFrame = 0

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(d.sampleRate),
            channels: AVAudioChannelCount(d.channels),
            interleaved: true
        )

        guard let format else { return }

        scheduleQueue.async { [weak self] in
            self?.scheduleBuffer(format: format)
        }

        playerNode.play()
        isPlaying = true
    }

    private func scheduleBuffer(format: AVAudioFormat) {
        guard let decoder else { return }

        let capacity = Int(frameBatch) * Int(decoder.channels)
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
            playerNode.pause()
            isPlaying = false
        }
    }

    func resume() {
        if !playerNode.isPlaying && decoder != nil {
            playerNode.play()
            isPlaying = true
        }
    }

    func stop() {
        playerNode.stop()
        decoder?.close()
        decoder = nil
        currentTrackPath = nil
        currentFrame = 0
        isPlaying = false
    }

    func seek(to time: Double) {
        guard let decoder, let path = currentTrackPath else { return }
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

    func setVolume(_ volume: Float) {
        playerNode.volume = volume
    }

    var duration: Double {
        guard let decoder else { return 0 }
        return decoder.durationSeconds
    }

    deinit {
        stop()
        engine.stop()
    }
}
