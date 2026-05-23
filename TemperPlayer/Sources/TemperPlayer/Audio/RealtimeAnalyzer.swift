import Foundation
import AVFAudio
import Accelerate
import os

final class RealtimeAnalyzer: ObservableObject {
    private weak var engine: AVAudioEngine?
    private let fftSize = 4096
    private let tapBufferSize: UInt32 = 512
    private let spectrumBarCount = 128
    private let waveformPointCount = 360
    private let fftSetup: FFTSetup
    private let log2n: vDSP_Length
    private var window: [Float]
    private var tapInstalled = false
    private var fftInputHistory: [Float] = []
    private var lowpass200State: Float = 0
    private var lowpass350State: Float = 0
    private var lowpass900State: Float = 0
    private var lowpass5000State: Float = 0
    private var waveformHistoryBands: [[Float]] = [[], [], [], [], []]
    private var waveformBucketPeaks: [Float] = [0, 0, 0, 0, 0]
    private var waveformBucketFrames = 0

    // Sample rate from the engine's output format
    @Published private(set) var sampleRate: Float = 44100

    // Ring buffers
    private var goniometerSamples: [CGPoint] = []
    private let maxGoniometerSamples = 720
    private var spectrumDisplayBars: [Float]

    // Published state
    @Published var spectrogramLines: [[Float]] = []
    @Published var spectrumBars: [Float] = []
    @Published var waveformBands: [[Float]] = [[], [], [], [], []]
    @Published var goniometerPoints: [CGPoint] = []
    @Published var correlation: Float = 0
    @Published var bandLevels: [Float] = [0, 0, 0]
    @Published var bandCorrelations: [Float] = [0, 0, 0]
    @Published var peak: Float = 0
    @Published var rms: Float = 0

    // UI throttle
    private var lastUIUpdate = Date.distantPast
    private let uiUpdateInterval: TimeInterval = 1.0 / 120.0
    private let processingQueue = DispatchQueue(label: "com.temperplayer.analyzer", qos: .userInitiated)
    private let processingState = OSAllocatedUnfairLock<Bool>(initialState: false)

    init(engine: AVAudioEngine) {
        self.engine = engine
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        self.spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        fftInputHistory.reserveCapacity(fftSize + Int(tapBufferSize))
        for band in waveformHistoryBands.indices {
            waveformHistoryBands[band].reserveCapacity(waveformPointCount)
        }
    }

    func installTap() {
        guard let engine, !tapInstalled else { return }
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        sampleRate = Float(format.sampleRate)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
            self?.processOnAudioThread(buffer: buffer)
        }
        tapInstalled = true
    }

    func removeTap() {
        guard let engine, tapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        tapInstalled = false
    }

    func reinstallTap() {
        removeTap()
        installTap()
    }

    func reset() {
        goniometerSamples.removeAll(keepingCapacity: true)
        fftInputHistory.removeAll(keepingCapacity: true)
        waveformHistoryBands = [[], [], [], [], []]
        waveformBucketPeaks = [0, 0, 0, 0, 0]
        waveformBucketFrames = 0
        lowpass200State = 0
        lowpass350State = 0
        lowpass900State = 0
        lowpass5000State = 0
        spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        let update = { [weak self] in
            guard let self else { return }
            self.spectrogramLines = []
            self.spectrumBars = []
            self.waveformBands = [[], [], [], [], []]
            self.goniometerPoints = []
            self.correlation = 0
            self.bandLevels = [0, 0, 0]
            self.bandCorrelations = [0, 0, 0]
            self.peak = 0
            self.rms = 0
        }
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    private func processOnAudioThread(buffer: AVAudioPCMBuffer) {
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let data = buffer.floatChannelData else { return }

        let shouldProcess = processingState.withLock { isProcessing in
            if isProcessing { return false }
            isProcessing = true
            return true
        }
        guard shouldProcess else { return }

        let len = min(frameLength, fftSize)
        var left = [Float](repeating: 0, count: len)
        left.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else { return }
            memcpy(base, data[0], len * MemoryLayout<Float>.size)
        }

        var right: [Float]?
        if channels >= 2 {
            var r = [Float](repeating: 0, count: len)
            r.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base, data[1], len * MemoryLayout<Float>.size)
            }
            right = r
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.processingState.withLock { isProcessing in
                    isProcessing = false
                }
            }
            self.processCopiedSamples(left: left, right: right)
        }
    }

    private func processCopiedSamples(left: [Float], right: [Float]?) {
        let len = left.count
        guard len > 0 else { return }

        var mix = left
        if let right {
            vDSP_vadd(left, 1, right, 1, &mix, 1, vDSP_Length(len))
            var half: Float = 0.5
            vDSP_vsmul(mix, 1, &half, &mix, 1, vDSP_Length(len))
        }

        var p: Float = 0, sq: Float = 0
        vDSP_maxmgv(mix, 1, &p, vDSP_Length(len))
        vDSP_measqv(mix, 1, &sq, vDSP_Length(len))

        fftInputHistory.append(contentsOf: mix)
        if fftInputHistory.count > fftSize {
            fftInputHistory.removeFirst(fftInputHistory.count - fftSize)
        }

        let waveBands = updateScrollingWaveform(samples: mix)

        // Keep the audio tap cheap: waveform history is fed every callback, while
        // FFT and stereo analysis are computed only when there is a UI frame to publish.
        let now = Date()
        guard now.timeIntervalSince(lastUIUpdate) >= uiUpdateInterval else { return }
        lastUIUpdate = now

        let magnitudes = computeFFT(samples: fftInputHistory)
        let sBars = computeSpectrumBars(magnitudes: magnitudes)
        let bLevels = computeBandLevels(magnitudes: magnitudes)

        let corr: Float
        let gPoints: [CGPoint]
        if let right {
            corr = computeCorrelation(left: left, right: right)
            gPoints = makeGoniometerPoints(left: left, right: right)
        } else {
            corr = 0
            gPoints = []
        }

        if !gPoints.isEmpty {
            goniometerSamples.append(contentsOf: gPoints)
            if goniometerSamples.count > maxGoniometerSamples {
                goniometerSamples.removeFirst(goniometerSamples.count - maxGoniometerSamples)
            }
        }

        let bars = sBars
        let waveform = waveBands
        let gSamples = goniometerSamples
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.peak = p
            self.rms = sqrt(sq)
            self.spectrumBars = bars
            self.waveformBands = waveform
            self.goniometerPoints = gSamples
            self.correlation = corr
            self.bandLevels = bLevels
            self.bandCorrelations = [corr, corr, corr]
        }
    }

    private func computeFFT(samples: [Float]) -> [Float] {
        var padded = samples
        if padded.count < fftSize {
            padded.append(contentsOf: [Float](repeating: 0, count: fftSize - padded.count))
        }

        vDSP_vmul(padded, 1, window, 1, &padded, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        var realPart = [Float](repeating: 0, count: half)
        var imagPart = [Float](repeating: 0, count: half)
        var magnitudes = [Float](repeating: 0, count: half)

        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                padded.withUnsafeBufferPointer { buf in
                    let complexPtr = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(half))
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(half))
            }
        }

        var scale: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(half))

        return magnitudes
    }

    private func computeSpectrumBars(magnitudes: [Float]) -> [Float] {
        guard !magnitudes.isEmpty else { return spectrumDisplayBars }

        let nyquist = min(sampleRate * 0.5, 20_000)
        let minHz: Float = 30
        let maxHz = max(minHz + 1, nyquist)
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let half = magnitudes.count

        var rawBars = [Float](repeating: 0, count: spectrumBarCount)

        for index in 0..<spectrumBarCount {
            let t0 = Float(index) / Float(spectrumBarCount)
            let t1 = Float(index + 1) / Float(spectrumBarCount)
            let f0 = pow(10, logMin + (logMax - logMin) * t0)
            let f1 = pow(10, logMin + (logMax - logMin) * t1)
            let b0 = max(1, min(half - 1, Int(f0 * Float(fftSize) / sampleRate)))
            let b1 = max(b0 + 1, min(half, Int(f1 * Float(fftSize) / sampleRate)))

            var peak: Float = 0
            var sum: Float = 0
            for bin in b0..<b1 {
                let value = magnitudes[bin]
                peak = max(peak, value)
                sum += value
            }

            let avg = sum / Float(max(1, b1 - b0))
            let t = Float(index) / Float(max(1, spectrumBarCount - 1))
            let peakWeight: Float = 0.34 + 0.30 * pow(t, 1.15)
            let energy = max(peak * peakWeight + avg * (1 - peakWeight), 1e-12)
            let db = 10 * log10(energy)

            let tilt = -0.14 * pow(1 - t, 1.25) + 0.05 * pow(t, 1.6)
            let floorDb: Float = -88
            let topDb: Float = -10
            let linear = max(0, min(1, (db - floorDb) / (topDb - floorDb) + tilt))
            let normalized = pow(linear, 1.35)
            rawBars[index] = normalized
        }

        if spectrumDisplayBars.count != spectrumBarCount {
            spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        }

        for index in 0..<spectrumBarCount {
            let incoming = rawBars[index]
            let previous = spectrumDisplayBars[index]
            let decayed = previous * 0.58
            spectrumDisplayBars[index] = incoming >= previous ? incoming : max(incoming, decayed)
        }

        return spectrumDisplayBars
    }

    private func computeBandLevels(magnitudes: [Float]) -> [Float] {
        let half = magnitudes.count
        let binsPerHz = Float(fftSize) / sampleRate
        let freqBands: [(Float, Float)] = [(20, 250), (251, 5000), (5001, 20000)]
        return freqBands.map { low, high in
            let b0 = max(0, min(half - 1, Int(low * binsPerHz)))
            let b1 = max(0, min(half, Int(high * binsPerHz)))
            guard b1 > b0 else { return Float(b0 == b1 && b0 < half ? magnitudes[b0] : 0) }
            var sum: Float = 0
            for i in b0..<b1 { sum += magnitudes[i] }
            let avg = sum / Float(b1 - b0)
            let db = 10 * log10(max(1e-12, avg))
            let floorDb: Float = -82
            let topDb: Float = -24
            return max(0, min(1, (db - floorDb) / (topDb - floorDb)))
        }
    }

    private func updateScrollingWaveform(samples: [Float]) -> [[Float]] {
        guard !samples.isEmpty else { return waveformHistoryBands }

        let subAlpha = onePoleAlpha(cutoff: 200)
        let lowMidAlpha = onePoleAlpha(cutoff: 350)
        let midAlpha = onePoleAlpha(cutoff: 900)
        let upperMidAlpha = onePoleAlpha(cutoff: 5000)
        let framesPerPoint = max(32, Int(sampleRate / 300))

        // Use local accumulator to avoid data race with reset()
        var localPeaks: [Float] = [0, 0, 0, 0, 0]

        for sample in samples {
            lowpass200State += subAlpha * (sample - lowpass200State)
            lowpass350State += lowMidAlpha * (sample - lowpass350State)
            lowpass900State += midAlpha * (sample - lowpass900State)
            lowpass5000State += upperMidAlpha * (sample - lowpass5000State)

            let subSample = lowpass200State                               // 0–200 Hz
            let lowMidSample = lowpass350State - lowpass200State           // 200–350 Hz
            let midSample = lowpass900State - lowpass350State              // 350–900 Hz
            let upperMidSample = lowpass5000State - lowpass900State        // 900–5000 Hz
            let highSample = sample - lowpass5000State                     // 5000+ Hz

            localPeaks[0] = max(localPeaks[0], waveformAmplitude(subSample, gain: 1.8))
            localPeaks[1] = max(localPeaks[1], waveformAmplitude(lowMidSample, gain: 2.5))
            localPeaks[2] = max(localPeaks[2], waveformAmplitude(midSample, gain: 3.0))
            localPeaks[3] = max(localPeaks[3], waveformAmplitude(upperMidSample, gain: 2.0))
            localPeaks[4] = max(localPeaks[4], waveformAmplitude(highSample, gain: 4.5))
            waveformBucketFrames += 1

            if waveformBucketFrames >= framesPerPoint {
                appendWaveformPoint(localPeaks)
                localPeaks = [0, 0, 0, 0, 0]
                waveformBucketFrames = 0
            }
        }

        return waveformHistoryBands
    }

    private func onePoleAlpha(cutoff: Float) -> Float {
        1 - exp(-2 * .pi * cutoff / max(1, sampleRate))
    }

    private func appendWaveformPoint(_ point: [Float]) {
        if waveformHistoryBands.count != 5 {
            waveformHistoryBands = [[], [], [], [], []]
        }

        for band in 0..<5 {
            waveformHistoryBands[band].append(point[band])
            if waveformHistoryBands[band].count > waveformPointCount {
                waveformHistoryBands[band].removeFirst(waveformHistoryBands[band].count - waveformPointCount)
            }
        }
    }

    private func waveformAmplitude(_ value: Float, gain: Float) -> Float {
        max(0, min(1, abs(value) * gain))
    }

    private func computeCorrelation(l: UnsafePointer<Float>, r: UnsafePointer<Float>, count: Int) -> Float {
        let n = min(count, 2048)
        var cov: Float = 0
        // Simplified: cosine similarity of zero-mean signals
        var lMean: Float = 0, rMean: Float = 0
        vDSP_meanv(l, 1, &lMean, vDSP_Length(n))
        vDSP_meanv(r, 1, &rMean, vDSP_Length(n))
        var lz = [Float](repeating: 0, count: n)
        var rz = [Float](repeating: 0, count: n)
        vDSP_vsadd(l, 1, [-lMean], &lz, 1, vDSP_Length(n))
        vDSP_vsadd(r, 1, [-rMean], &rz, 1, vDSP_Length(n))
        vDSP_dotpr(lz, 1, rz, 1, &cov, vDSP_Length(n))
        var lv: Float = 0, rv: Float = 0
        vDSP_dotpr(lz, 1, lz, 1, &lv, vDSP_Length(n))
        vDSP_dotpr(rz, 1, rz, 1, &rv, vDSP_Length(n))
        let denom = sqrt(lv * rv)
        return denom > 0 ? max(-1, min(1, cov / denom)) : 0
    }

    private func computeCorrelation(left: [Float], right: [Float]) -> Float {
        let n = min(left.count, right.count, 512)
        guard n > 0 else { return 0 }
        return left.withUnsafeBufferPointer { lbuf in
            right.withUnsafeBufferPointer { rbuf in
                guard let l = lbuf.baseAddress, let r = rbuf.baseAddress else { return 0 }
                return computeCorrelation(l: l, r: r, count: n)
            }
        }
    }

    private func makeGoniometerPoints(left: [Float], right: [Float]) -> [CGPoint] {
        let count = min(left.count, right.count)
        let step = max(1, count / 96)
        return stride(from: 0, to: count, by: step).map { i in
            CGPoint(x: CGFloat(left[i]), y: CGFloat(right[i]))
        }
    }

    deinit {
        removeTap()
        vDSP_destroy_fftsetup(fftSetup)
    }
}
