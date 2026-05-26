import Foundation
import AVFAudio
import Accelerate
import Combine
import CoreVideo
import os

private struct AnalyzerSnapshot {
    let frameCount: Int
    let callbackTimeNs: UInt64
    let analysisStartTimeNs: UInt64
    let analysisEndTimeNs: UInt64
    let audioHostTime: UInt64
    let peak: Float
    let rms: Float
    let spectrumBars: [Float]
    let waveformBands: [[Float]]
    let waveformPositive: [Float]
    let waveformNegative: [Float]
    let waveformScrollPhase: Float
    let goniometerPoints: [CGPoint]
    let goniometerBassPoints: [CGPoint]
    let goniometerMidPoints: [CGPoint]
    let goniometerHighPoints: [CGPoint]
    let correlation: Float
    let bandLevels: [Float]
}

private struct PublishBuffer {
    var scheduled = false
    var snapshot: AnalyzerSnapshot?
}

private struct VisualFrameQueue {
    var snapshots: [AnalyzerSnapshot?]
    var readIndex = 0
    var writeIndex = 0
    var count = 0

    init(capacity: Int) {
        snapshots = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }

    mutating func push(_ snapshot: AnalyzerSnapshot) -> Bool {
        guard !snapshots.isEmpty else { return true }
        var dropped = false
        if count == snapshots.count {
            snapshots[readIndex] = nil
            readIndex = (readIndex + 1) % snapshots.count
            count -= 1
            dropped = true
        }
        snapshots[writeIndex] = snapshot
        writeIndex = (writeIndex + 1) % snapshots.count
        count += 1
        return dropped
    }

    mutating func pop(count requestedCount: Int) -> AnalyzerSnapshot? {
        guard count > 0 else { return nil }
        var result: AnalyzerSnapshot?
        let framesToPop = min(max(1, requestedCount), count)
        for _ in 0..<framesToPop {
            result = snapshots[readIndex]
            snapshots[readIndex] = nil
            readIndex = (readIndex + 1) % snapshots.count
            count -= 1
        }
        return result
    }

    mutating func removeAll() {
        for index in snapshots.indices {
            snapshots[index] = nil
        }
        readIndex = 0
        writeIndex = 0
        count = 0
    }
}

private struct LatencyProbeState {
    var callbackToAnalysisMs: [Double] = []
    var analysisDurationMs: [Double] = []
    var analysisToMainMs: [Double] = []
    var callbackToMainMs: [Double] = []
    var tapFrameCounts: [Double] = []
    var droppedTaps = 0
    var coalescedPublishes = 0
    var enqueuedSnapshots = 0
    var displayTicks = 0
    var displaySchedules = 0
    var displaySkips = 0
    var renderFrames = 0
    var lastReportTimeNs = DispatchTime.now().uptimeNanoseconds

    mutating func recordPublish(snapshot: AnalyzerSnapshot, mainTimeNs: UInt64) -> String? {
        callbackToAnalysisMs.append(ms(snapshot.analysisStartTimeNs, snapshot.callbackTimeNs))
        analysisDurationMs.append(ms(snapshot.analysisEndTimeNs, snapshot.analysisStartTimeNs))
        analysisToMainMs.append(ms(mainTimeNs, snapshot.analysisEndTimeNs))
        callbackToMainMs.append(ms(mainTimeNs, snapshot.callbackTimeNs))
        tapFrameCounts.append(Double(snapshot.frameCount))

        guard mainTimeNs - lastReportTimeNs >= 2_000_000_000 else { return nil }
        defer {
            callbackToAnalysisMs.removeAll(keepingCapacity: true)
            analysisDurationMs.removeAll(keepingCapacity: true)
            analysisToMainMs.removeAll(keepingCapacity: true)
            callbackToMainMs.removeAll(keepingCapacity: true)
            tapFrameCounts.removeAll(keepingCapacity: true)
            droppedTaps = 0
            coalescedPublishes = 0
            enqueuedSnapshots = 0
            displayTicks = 0
            displaySchedules = 0
            displaySkips = 0
            renderFrames = 0
            lastReportTimeNs = mainTimeNs
        }

        return """
        [analyzer latency] frames=\(callbackToMainMs.count) enqueued=\(enqueuedSnapshots) dropped_taps=\(droppedTaps) coalesced_publishes=\(coalescedPublishes)
          display ticks     ticks=\(displayTicks) scheduled=\(displaySchedules) skipped=\(displaySkips) rendered=\(renderFrames)
          tap frame count    \(frameSummary(tapFrameCounts))
          callback->analysis \(summary(callbackToAnalysisMs))
          analysis duration  \(summary(analysisDurationMs))
          analysis->main     \(summary(analysisToMainMs))
          callback->main     \(summary(callbackToMainMs))
        """
    }

    private func ms(_ end: UInt64, _ start: UInt64) -> Double {
        guard end >= start else { return 0 }
        return Double(end - start) / 1_000_000
    }

    private func summary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        return String(
            format: "p50=%.2fms p95=%.2fms p99=%.2fms max=%.2fms",
            percentile(sorted, 0.50),
            percentile(sorted, 0.95),
            percentile(sorted, 0.99),
            sorted.last ?? 0
        )
    }

    private func frameSummary(_ values: [Double]) -> String {
        guard !values.isEmpty else { return "n/a" }
        let sorted = values.sorted()
        return String(
            format: "p50=%.0f p95=%.0f p99=%.0f max=%.0f",
            percentile(sorted, 0.50),
            percentile(sorted, 0.95),
            percentile(sorted, 0.99),
            sorted.last ?? 0
        )
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded(.up))))
        return sorted[index]
    }
}

final class RealtimeAnalyzer: ObservableObject {
    private weak var engine: AVAudioEngine?
    private weak var tapNode: AVAudioNode?
    private let fftSize = 4096
    private let fastFFTSize = 1024
    private let tapBufferSize: UInt32 = 256
    private let analysisChunkSize = 256
    private let spectrumBarCount = 128
    private let waveformPointCount = 360
    private let fftSetup: FFTSetup
    private let fastFFTSetup: FFTSetup
    private let log2n: vDSP_Length
    private let fastLog2n: vDSP_Length
    private var window: [Float]
    private var fastWindow: [Float]
    private var fftInputBuffer: [Float]
    private var fftRealPart: [Float]
    private var fftImagPart: [Float]
    private var fftMagnitudes: [Float]
    private var longMagnitudeCache: [Float]
    private var fastFFTInputBuffer: [Float]
    private var fastFFTRealPart: [Float]
    private var fastFFTImagPart: [Float]
    private var fastFFTMagnitudes: [Float]
    private var captureLeft: [Float]
    private var captureRight: [Float]
    private var mixScratch: [Float]
    private var correlationLeftZero: [Float]
    private var correlationRightZero: [Float]
    private var goniometerPointScratch: [CGPoint] = []
    private var spectrumRawBars: [Float]
    private var spectrumLongBinStarts: [Int]
    private var spectrumLongBinEnds: [Int]
    private var spectrumFastBinStarts: [Int]
    private var spectrumFastBinEnds: [Int]
    private var spectrumPeakWeights: [Float]
    private var spectrumFastWeights: [Float]
    private var spectrumTiltsDb: [Float]
    private var spectrumLongEnergyCache: [Float]
    private var spectrumMappingSampleRate: Float = 0
    private var bandLevelScratch: [Float]
    private var cachedBandLevels: [Float]
    private var hasLongFFTCache = false
    private var longFFTCountdown = 0
    private let longFFTRefreshInterval = 3
    private var tapInstalled = false
    private var fftHistoryRing: [Float]
    private var fftHistoryWriteIndex = 0
    private var fftHistoryCount = 0
    private var lowpass80State: Float = 0
    private var lowpass250State: Float = 0
    private var lowpass400State: Float = 0
    private var lowpass1300State: Float = 0
    private var lowpass5000State: Float = 0
    private var lowpass80State2: Float = 0
    private var lowpass250State2: Float = 0
    private var lowpass400State2: Float = 0
    private var lowpass1300State2: Float = 0
    private var lowpass5000State2: Float = 0
    private var lowpass80Alpha: Float = 0
    private var lowpass250Alpha: Float = 0
    private var lowpass400Alpha: Float = 0
    private var lowpass1300Alpha: Float = 0
    private var lowpass5000Alpha: Float = 0

    // Per-band goniometer filter states (two-pole per channel)
    private var gonLowL: Float = 0, gonLowL2: Float = 0
    private var gonLowR: Float = 0, gonLowR2: Float = 0
    private var gonMidL: Float = 0, gonMidL2: Float = 0
    private var gonMidR: Float = 0, gonMidR2: Float = 0
    private var gonLowAlpha: Float = 0
    private var gonMidAlpha: Float = 0
    private var framesPerWaveformPoint = 147
    private var waveformScrollPhase: Float = 0
    private var waveformHistoryBands: [[Float]] = [[], [], [], [], [], []]
    private var waveformPositiveHistory: [Float] = []
    private var waveformNegativeHistory: [Float] = []
    private var waveformBucketPeaks: [Float] = [0, 0, 0, 0, 0, 0]
    private var waveformBucketPositive: Float = 0
    private var waveformBucketNegative: Float = 0
    private var waveformBucketFrames = 0

    // Sample rate from the engine's output format
    private(set) var sampleRate: Float = 44100

    // Ring buffers
    private var goniometerSamples: [CGPoint] = []
    private let maxGoniometerSamples = 720
    private var goniometerBassSamples: [CGPoint] = []
    private var goniometerMidSamples: [CGPoint] = []
    private var goniometerHighSamples: [CGPoint] = []
    private var spectrumDisplayBars: [Float]

    // Published state
    private(set) var spectrogramLines: [[Float]] = []
    private(set) var spectrumBars: [Float] = []
    private(set) var waveformBands: [[Float]] = [[], [], [], [], [], []]
    private(set) var waveformPositive: [Float] = []
    private(set) var waveformNegative: [Float] = []
    var waveformVisiblePointCount: Int { waveformPointCount }
    private(set) var waveformPhase: Float = 0
    private(set) var goniometerPoints: [CGPoint] = []
    private(set) var goniometerBassPoints: [CGPoint] = []
    private(set) var goniometerMidPoints: [CGPoint] = []
    private(set) var goniometerHighPoints: [CGPoint] = []
    private(set) var correlation: Float = 0
    private(set) var bandLevels: [Float] = [0, 0, 0]
    private(set) var bandCorrelations: [Float] = [0, 0, 0]
    private(set) var peak: Float = 0
    private(set) var rms: Float = 0
    var isFrozen = false

    // Display pacing
    private let displayDrawScale = 1.0
    private let visualSmoothing: Float = 0.90
    private let processingQueue = DispatchQueue(label: "com.temperplayer.analyzer", qos: .userInitiated)
    private let processingState = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let publishBuffer = OSAllocatedUnfairLock<PublishBuffer>(initialState: PublishBuffer())
    private let visualFrameQueue: OSAllocatedUnfairLock<VisualFrameQueue>
    private let displayTickScheduled = OSAllocatedUnfairLock<Bool>(initialState: false)
    private let displayDrawDebt = OSAllocatedUnfairLock<Double>(initialState: 0)
    private let latencyProbeState = OSAllocatedUnfairLock<LatencyProbeState>(initialState: LatencyProbeState())
    private let latencyProbesEnabled = ProcessInfo.processInfo.environment["ANALYZER_LATENCY_PROBES"] == "1"
    private let lowLatencySpectrumEnabled = ProcessInfo.processInfo.environment["TEMPER_LOW_LATENCY_SPECTRUM"] != "0"
    private var displayLink: CVDisplayLink?
    private var lastDisplayTickTimeNs: UInt64 = 0
    private var visualFrameDebt = 0.0

    init(engine: AVAudioEngine, tapNode: AVAudioNode? = nil) {
        self.engine = engine
        self.tapNode = tapNode
        self.log2n = vDSP_Length(log2(Float(fftSize)))
        self.fastLog2n = vDSP_Length(log2(Float(fastFFTSize)))
        self.fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.fastFFTSetup = vDSP_create_fftsetup(fastLog2n, FFTRadix(kFFTRadix2))!
        self.window = [Float](repeating: 0, count: fftSize)
        self.fastWindow = [Float](repeating: 0, count: fastFFTSize)
        self.fftInputBuffer = [Float](repeating: 0, count: fftSize)
        self.fftRealPart = [Float](repeating: 0, count: fftSize / 2)
        self.fftImagPart = [Float](repeating: 0, count: fftSize / 2)
        self.fftMagnitudes = [Float](repeating: 0, count: fftSize / 2)
        self.longMagnitudeCache = [Float](repeating: 0, count: fftSize / 2)
        self.fastFFTInputBuffer = [Float](repeating: 0, count: fastFFTSize)
        self.fastFFTRealPart = [Float](repeating: 0, count: fastFFTSize / 2)
        self.fastFFTImagPart = [Float](repeating: 0, count: fastFFTSize / 2)
        self.fastFFTMagnitudes = [Float](repeating: 0, count: fastFFTSize / 2)
        self.captureLeft = [Float](repeating: 0, count: fftSize)
        self.captureRight = [Float](repeating: 0, count: fftSize)
        self.mixScratch = [Float](repeating: 0, count: fftSize)
        self.correlationLeftZero = [Float](repeating: 0, count: 512)
        self.correlationRightZero = [Float](repeating: 0, count: 512)
        self.spectrumRawBars = [Float](repeating: 0, count: spectrumBarCount)
        self.spectrumLongBinStarts = [Int](repeating: 1, count: spectrumBarCount)
        self.spectrumLongBinEnds = [Int](repeating: 2, count: spectrumBarCount)
        self.spectrumFastBinStarts = [Int](repeating: 1, count: spectrumBarCount)
        self.spectrumFastBinEnds = [Int](repeating: 2, count: spectrumBarCount)
        self.spectrumPeakWeights = [Float](repeating: 0, count: spectrumBarCount)
        self.spectrumFastWeights = [Float](repeating: 0, count: spectrumBarCount)
        self.spectrumTiltsDb = [Float](repeating: 0, count: spectrumBarCount)
        self.spectrumLongEnergyCache = [Float](repeating: 1e-12, count: spectrumBarCount)
        self.bandLevelScratch = [Float](repeating: 0, count: 3)
        self.cachedBandLevels = [Float](repeating: 0, count: 3)
        self.spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        self.fftHistoryRing = [Float](repeating: 0, count: fftSize)
        self.visualFrameQueue = OSAllocatedUnfairLock(initialState: VisualFrameQueue(capacity: 512))

        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        for index in fastWindow.indices {
            let t = Float(index) / Float(max(1, fastFFTSize - 1))
            let eased = sin(t * .pi * 0.5)
            fastWindow[index] = 0.08 + 0.92 * eased * eased
        }

        goniometerPointScratch.reserveCapacity(128)
        for band in waveformHistoryBands.indices {
            waveformHistoryBands[band].reserveCapacity(waveformPointCount)
        }
        waveformPositiveHistory.reserveCapacity(waveformPointCount)
        waveformNegativeHistory.reserveCapacity(waveformPointCount)
        configureAnalysis(for: sampleRate)
    }

    func installTap() {
        guard let engine, !tapInstalled else { return }
        let node = tapNode ?? engine.mainMixerNode
        let format = node.outputFormat(forBus: 0)
        sampleRate = Float(format.sampleRate)
        configureAnalysis(for: sampleRate)
        node.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, time in
            self?.processOnAudioThread(buffer: buffer, audioTime: time)
        }
        tapInstalled = true
        startDisplayLink()
    }

    func removeTap() {
        guard let engine, tapInstalled else { return }
        let node = tapNode ?? engine.mainMixerNode
        node.removeTap(onBus: 0)
        tapInstalled = false
        stopDisplayLink()
    }

    func reinstallTap() {
        removeTap()
        installTap()
    }

    func reset() {
        goniometerSamples.removeAll(keepingCapacity: true)
        goniometerBassSamples.removeAll(keepingCapacity: true)
        goniometerMidSamples.removeAll(keepingCapacity: true)
        goniometerHighSamples.removeAll(keepingCapacity: true)
        fftHistoryWriteIndex = 0
        fftHistoryCount = 0
        waveformHistoryBands = [[], [], [], [], [], []]
        waveformPositiveHistory = []
        waveformNegativeHistory = []
        waveformBucketPeaks = [0, 0, 0, 0, 0, 0]
        waveformBucketPositive = 0
        waveformBucketNegative = 0
        waveformBucketFrames = 0
        waveformScrollPhase = 0
        lowpass80State = 0
        lowpass250State = 0
        lowpass400State = 0
        lowpass1300State = 0
        lowpass5000State = 0
        lowpass80State2 = 0
        lowpass250State2 = 0
        lowpass400State2 = 0
        lowpass1300State2 = 0
        lowpass5000State2 = 0
        spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        spectrumLongEnergyCache = [Float](repeating: 1e-12, count: spectrumBarCount)
        hasLongFFTCache = false
        longFFTCountdown = 0
        publishBuffer.withLock {
            $0.scheduled = false
            $0.snapshot = nil
        }
        visualFrameQueue.withLock { $0.removeAll() }
        displayDrawDebt.withLock { $0 = 0 }
        lastDisplayTickTimeNs = 0
        visualFrameDebt = 0
        let update = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.spectrogramLines = []
            self.spectrumBars = []
            self.waveformBands = [[], [], [], [], [], []]
            self.waveformPositive = []
            self.waveformNegative = []
            self.waveformPhase = 0
            self.goniometerPoints = []
            self.goniometerBassPoints = []
            self.goniometerMidPoints = []
            self.goniometerHighPoints = []
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

    private func processOnAudioThread(buffer: AVAudioPCMBuffer, audioTime: AVAudioTime) {
        let callbackTimeNs = DispatchTime.now().uptimeNanoseconds
        let channels = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0, let data = buffer.floatChannelData else { return }

        let shouldProcess = processingState.withLock { isProcessing in
            if isProcessing { return false }
            isProcessing = true
            return true
        }
        guard shouldProcess else {
            recordDroppedTap()
            return
        }

        let len = min(frameLength, fftSize)
        captureLeft.withUnsafeMutableBufferPointer { dst in
            guard let base = dst.baseAddress else {
                recordDroppedTap()
                return
            }
            memcpy(base, data[0], len * MemoryLayout<Float>.size)
        }

        let hasRight = channels >= 2
        if hasRight {
            captureRight.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                memcpy(base, data[1], len * MemoryLayout<Float>.size)
            }
        }

        processingQueue.async { [weak self] in
            guard let self else { return }
            defer {
                self.processingState.withLock { isProcessing in
                    isProcessing = false
                }
            }
            var offset = 0
            while offset < len {
                let chunkLength = min(self.analysisChunkSize, len - offset)
                self.processCopiedSamples(
                    frameOffset: offset,
                    frameCount: chunkLength,
                    hasRight: hasRight,
                    callbackTimeNs: callbackTimeNs,
                    audioHostTime: audioTime.hostTime
                )
                offset += chunkLength
            }
        }
    }

    private func processCopiedSamples(frameOffset offset: Int, frameCount len: Int, hasRight: Bool, callbackTimeNs: UInt64, audioHostTime: UInt64) {
        let analysisStartTimeNs = DispatchTime.now().uptimeNanoseconds
        guard len > 0 else { return }

        captureLeft.withUnsafeBufferPointer { src in
            mixScratch.withUnsafeMutableBufferPointer { dst in
                guard let srcBase = src.baseAddress, let dstBase = dst.baseAddress else { return }
                memcpy(dstBase, srcBase.advanced(by: offset), len * MemoryLayout<Float>.size)
            }
        }

        if hasRight {
            captureLeft.withUnsafeBufferPointer { left in
                captureRight.withUnsafeBufferPointer { right in
                    mixScratch.withUnsafeMutableBufferPointer { mix in
                        guard let leftBase = left.baseAddress,
                              let rightBase = right.baseAddress,
                              let mixBase = mix.baseAddress else { return }
                        vDSP_vadd(
                            leftBase.advanced(by: offset),
                            1,
                            rightBase.advanced(by: offset),
                            1,
                            mixBase,
                            1,
                            vDSP_Length(len)
                        )
                        var half: Float = 0.5
                        vDSP_vsmul(mixBase, 1, &half, mixBase, 1, vDSP_Length(len))
                    }
                }
            }
        }

        var p: Float = 0, sq: Float = 0
        vDSP_maxmgv(mixScratch, 1, &p, vDSP_Length(len))
        vDSP_measqv(mixScratch, 1, &sq, vDSP_Length(len))

        appendFFTInput(samples: mixScratch, count: len)

        let waveBands = updateScrollingWaveform(samples: mixScratch, count: len)

        let fastMagnitudes = lowLatencySpectrumEnabled ? computeFastFFT() : nil
        let shouldRefreshLongFFT = !hasLongFFTCache || longFFTCountdown <= 0 || !lowLatencySpectrumEnabled
        if shouldRefreshLongFFT {
            let longMagnitudes = computeLongFFT()
            cacheLongMagnitudes(longMagnitudes)
            cacheLongSpectrumEnergies(magnitudes: longMagnitudes)
            cachedBandLevels = computeBandLevels(magnitudes: longMagnitudes)
            hasLongFFTCache = true
            longFFTCountdown = max(0, longFFTRefreshInterval - 1)
        } else {
            longFFTCountdown -= 1
        }

        let sBars = computeSpectrumBars(fastMagnitudes: fastMagnitudes)
        let bLevels = cachedBandLevels

        let corr: Float
        let gPoints: [CGPoint]
        let gBassPoints: [CGPoint]
        let gMidPoints: [CGPoint]
        let gHighPoints: [CGPoint]
        if hasRight {
            corr = computeCorrelation(left: captureLeft, right: captureRight, offset: offset, count: len)
            gPoints = makeGoniometerPoints(left: captureLeft, right: captureRight, offset: offset, count: len)
            gBassPoints = processGoniometerBand(
                left: captureLeft, right: captureRight,
                offset: offset, count: len,
                alpha: gonLowAlpha,
                leftState: &gonLowL, leftState2: &gonLowL2,
                rightState: &gonLowR, rightState2: &gonLowR2
            )
            gMidPoints = processGoniometerBand(
                left: captureLeft, right: captureRight,
                offset: offset, count: len,
                alpha: gonMidAlpha,
                leftState: &gonMidL, leftState2: &gonMidL2,
                rightState: &gonMidR, rightState2: &gonMidR2
            )
            // High band: subtract the mid-pass filtered signal from raw
            gHighPoints = processGoniometerBandHigh(
                left: captureLeft, right: captureRight,
                offset: offset, count: len,
                midLeft: gonMidL2, midRight: gonMidR2
            )
        } else {
            corr = 0
            gPoints = []
            gBassPoints = []
            gMidPoints = []
            gHighPoints = []
        }

        if !gPoints.isEmpty {
            goniometerSamples.append(contentsOf: gPoints)
            if goniometerSamples.count > maxGoniometerSamples {
                goniometerSamples.removeFirst(goniometerSamples.count - maxGoniometerSamples)
            }
        }
        if !gBassPoints.isEmpty {
            goniometerBassSamples.append(contentsOf: gBassPoints)
            if goniometerBassSamples.count > maxGoniometerSamples {
                goniometerBassSamples.removeFirst(goniometerBassSamples.count - maxGoniometerSamples)
            }
        }
        if !gMidPoints.isEmpty {
            goniometerMidSamples.append(contentsOf: gMidPoints)
            if goniometerMidSamples.count > maxGoniometerSamples {
                goniometerMidSamples.removeFirst(goniometerMidSamples.count - maxGoniometerSamples)
            }
        }
        if !gHighPoints.isEmpty {
            goniometerHighSamples.append(contentsOf: gHighPoints)
            if goniometerHighSamples.count > maxGoniometerSamples {
                goniometerHighSamples.removeFirst(goniometerHighSamples.count - maxGoniometerSamples)
            }
        }

        let snapshot = AnalyzerSnapshot(
            frameCount: len,
            callbackTimeNs: callbackTimeNs,
            analysisStartTimeNs: analysisStartTimeNs,
            analysisEndTimeNs: DispatchTime.now().uptimeNanoseconds,
            audioHostTime: audioHostTime,
            peak: p,
            rms: sqrt(sq),
            spectrumBars: sBars,
            waveformBands: waveBands,
            waveformPositive: waveformPositiveHistory,
            waveformNegative: waveformNegativeHistory,
            waveformScrollPhase: waveformScrollPhase,
            goniometerPoints: goniometerSamples,
            goniometerBassPoints: goniometerBassSamples,
            goniometerMidPoints: goniometerMidSamples,
            goniometerHighPoints: goniometerHighSamples,
            correlation: corr,
            bandLevels: bLevels
        )
        enqueuePublish(snapshot)
    }

    private func enqueuePublish(_ snapshot: AnalyzerSnapshot) {
        recordEnqueuedSnapshot()
        let dropped = visualFrameQueue.withLock { queue in
            queue.push(snapshot)
        }
        if dropped {
            recordCoalescedPublish()
        }
    }

    private func publishSnapshot(_ snapshot: AnalyzerSnapshot) {
        guard !isFrozen else { return }
        objectWillChange.send()
        peak = smoothScalar(current: peak, target: snapshot.peak)
        rms = smoothScalar(current: rms, target: snapshot.rms)
        smoothArray(&spectrumBars, target: snapshot.spectrumBars)
        waveformBands = snapshot.waveformBands
        waveformPositive = snapshot.waveformPositive
        waveformNegative = snapshot.waveformNegative
        waveformPhase = snapshot.waveformScrollPhase
        goniometerPoints = snapshot.goniometerPoints
        goniometerBassPoints = snapshot.goniometerBassPoints
        goniometerMidPoints = snapshot.goniometerMidPoints
        goniometerHighPoints = snapshot.goniometerHighPoints
        correlation = smoothScalar(current: correlation, target: snapshot.correlation)
        smoothArray(&bandLevels, target: snapshot.bandLevels)
        bandCorrelations = [correlation, correlation, correlation]

        recordRenderFrame()
        recordPublish(snapshot: snapshot, mainTimeNs: DispatchTime.now().uptimeNanoseconds)
    }

    private func smoothScalar(current: Float, target: Float) -> Float {
        current * visualSmoothing + target * (1 - visualSmoothing)
    }

    private func smoothArray(_ current: inout [Float], target: [Float]) {
        guard current.count == target.count else {
            current = target
            return
        }
        for index in current.indices {
            current[index] = current[index] * visualSmoothing + target[index] * (1 - visualSmoothing)
        }
    }

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var newDisplayLink: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink) == kCVReturnSuccess,
              let newDisplayLink else {
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(newDisplayLink, { _, _, _, _, _, context in
            guard let context else { return kCVReturnSuccess }
            let analyzer = Unmanaged<RealtimeAnalyzer>.fromOpaque(context).takeUnretainedValue()
            analyzer.scheduleDisplayTick()
            return kCVReturnSuccess
        }, context)

        if CVDisplayLinkStart(newDisplayLink) == kCVReturnSuccess {
            displayLink = newDisplayLink
        }
    }

    private func stopDisplayLink() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
        displayTickScheduled.withLock { $0 = false }
        displayDrawDebt.withLock { $0 = 0 }
        lastDisplayTickTimeNs = 0
        visualFrameDebt = 0
    }

    private func scheduleDisplayTick() {
        let shouldSchedule = displayTickScheduled.withLock { scheduled in
            if scheduled { return false }
            scheduled = true
            return true
        }
        recordDisplayTick(scheduled: shouldSchedule)
        guard shouldSchedule else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.publishQueuedVisualFrame()
            self.displayTickScheduled.withLock { $0 = false }
        }
    }

    private func publishQueuedVisualFrame() {
        let now = DispatchTime.now().uptimeNanoseconds
        let elapsedSeconds: Double
        if lastDisplayTickTimeNs == 0 {
            elapsedSeconds = Double(analysisChunkSize) / Double(max(1, sampleRate))
        } else {
            elapsedSeconds = min(0.050, max(0, Double(now - lastDisplayTickTimeNs) / 1_000_000_000))
        }
        lastDisplayTickTimeNs = now

        let chunkRate = Double(max(1, sampleRate)) / Double(analysisChunkSize)
        visualFrameDebt += elapsedSeconds * chunkRate
        let framesToConsume = max(1, Int(visualFrameDebt.rounded(.down)))
        visualFrameDebt = max(0, visualFrameDebt - Double(framesToConsume))

        let snapshot = visualFrameQueue.withLock { queue in
            queue.pop(count: framesToConsume)
        }
        guard let snapshot else {
            visualFrameDebt = 0
            publishDisplayOnlyFrame(elapsedSeconds: elapsedSeconds)
            return
        }

        publishSnapshot(snapshot)
    }

    private func publishDisplayOnlyFrame(elapsedSeconds: Double) {
        guard !isFrozen, !waveformBands.isEmpty, !(waveformBands.first?.isEmpty ?? true) else { return }
        objectWillChange.send()
        let phaseAdvance = Float(Double(max(1, sampleRate)) * elapsedSeconds / Double(max(1, framesPerWaveformPoint)))
        waveformPhase = (waveformPhase + phaseAdvance).truncatingRemainder(dividingBy: 1)
        recordRenderFrame()
    }

    private func appendFFTInput(samples: [Float], count: Int) {
        let sourceOffset = max(0, count - fftSize)
        let framesToCopy = min(count, fftSize)
        guard framesToCopy > 0 else { return }

        samples.withUnsafeBufferPointer { source in
            fftHistoryRing.withUnsafeMutableBufferPointer { ring in
                guard let sourceBase = source.baseAddress, let ringBase = ring.baseAddress else { return }
                let first = min(framesToCopy, fftSize - fftHistoryWriteIndex)
                memcpy(
                    ringBase.advanced(by: fftHistoryWriteIndex),
                    sourceBase.advanced(by: sourceOffset),
                    first * MemoryLayout<Float>.size
                )
                if first < framesToCopy {
                    memcpy(
                        ringBase,
                        sourceBase.advanced(by: sourceOffset + first),
                        (framesToCopy - first) * MemoryLayout<Float>.size
                    )
                }
            }
        }

        fftHistoryWriteIndex = (fftHistoryWriteIndex + framesToCopy) % fftSize
        fftHistoryCount = min(fftSize, fftHistoryCount + framesToCopy)
    }

    private func copyFFTInput(into output: inout [Float], length: Int) {
        let available = min(fftHistoryCount, length)
        let padding = length - available

        output.withUnsafeMutableBufferPointer { dst in
            guard let dstBase = dst.baseAddress else { return }
            if padding > 0 {
                vDSP_vclr(dstBase, 1, vDSP_Length(padding))
            }
            guard available > 0 else { return }

            let start = (fftHistoryWriteIndex - available + fftSize) % fftSize
            fftHistoryRing.withUnsafeBufferPointer { ring in
                guard let ringBase = ring.baseAddress else { return }
                let first = min(available, fftSize - start)
                memcpy(
                    dstBase.advanced(by: padding),
                    ringBase.advanced(by: start),
                    first * MemoryLayout<Float>.size
                )
                if first < available {
                    memcpy(
                        dstBase.advanced(by: padding + first),
                        ringBase,
                        (available - first) * MemoryLayout<Float>.size
                    )
                }
            }
        }
    }

    private func computeLongFFT() -> [Float] {
        let half = fftSize / 2
        copyFFTInput(into: &fftInputBuffer, length: fftSize)

        vDSP_vmul(fftInputBuffer, 1, window, 1, &fftInputBuffer, 1, vDSP_Length(fftSize))

        fftRealPart.withUnsafeMutableBufferPointer { realPtr in
            fftImagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                fftInputBuffer.withUnsafeBufferPointer { buf in
                    let complexPtr = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(half))
                }

                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &fftMagnitudes, 1, vDSP_Length(half))
            }
        }

        var scale: Float = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(fftMagnitudes, 1, &scale, &fftMagnitudes, 1, vDSP_Length(half))

        return fftMagnitudes
    }

    private func cacheLongMagnitudes(_ magnitudes: [Float]) {
        let count = min(longMagnitudeCache.count, magnitudes.count)
        longMagnitudeCache.withUnsafeMutableBufferPointer { dst in
            magnitudes.withUnsafeBufferPointer { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                memcpy(dstBase, srcBase, count * MemoryLayout<Float>.size)
            }
        }
    }

    private func computeFastFFT() -> [Float] {
        let half = fastFFTSize / 2
        copyFFTInput(into: &fastFFTInputBuffer, length: fastFFTSize)

        vDSP_vmul(fastFFTInputBuffer, 1, fastWindow, 1, &fastFFTInputBuffer, 1, vDSP_Length(fastFFTSize))

        fastFFTRealPart.withUnsafeMutableBufferPointer { realPtr in
            fastFFTImagPart.withUnsafeMutableBufferPointer { imagPtr in
                guard let realBase = realPtr.baseAddress, let imagBase = imagPtr.baseAddress else { return }
                var splitComplex = DSPSplitComplex(realp: realBase, imagp: imagBase)

                fastFFTInputBuffer.withUnsafeBufferPointer { buf in
                    let complexPtr = UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(half))
                }

                vDSP_fft_zrip(fastFFTSetup, &splitComplex, 1, fastLog2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvmags(&splitComplex, 1, &fastFFTMagnitudes, 1, vDSP_Length(half))
            }
        }

        var scale: Float = 1.0 / Float(fastFFTSize * fastFFTSize)
        vDSP_vsmul(fastFFTMagnitudes, 1, &scale, &fastFFTMagnitudes, 1, vDSP_Length(half))

        return fastFFTMagnitudes
    }

    private func cacheLongSpectrumEnergies(magnitudes: [Float]) {
        guard !magnitudes.isEmpty else { return }
        if spectrumMappingSampleRate != sampleRate {
            configureSpectrumMapping(for: sampleRate)
        }

        let longHalf = magnitudes.count
        for index in 0..<spectrumBarCount {
            let b0 = max(1, min(longHalf - 1, spectrumLongBinStarts[index]))
            let b1 = max(b0 + 1, min(longHalf, spectrumLongBinEnds[index]))
            spectrumLongEnergyCache[index] = spectrumEnergy(
                magnitudes: magnitudes,
                b0: b0,
                b1: b1,
                peakWeight: spectrumPeakWeights[index]
            )
        }
    }

    private func computeSpectrumBars(fastMagnitudes: [Float]?) -> [Float] {
        if spectrumMappingSampleRate != sampleRate {
            configureSpectrumMapping(for: sampleRate)
        }

        let fastHalf = fastMagnitudes?.count ?? 0

        for index in 0..<spectrumBarCount {
            let peakWeight = spectrumPeakWeights[index]
            let longEnergy = spectrumLongEnergyCache[index]

            let fastEnergy: Float
            if let fastMagnitudes, fastHalf > 1 {
                let fastB0 = max(1, min(fastHalf - 1, spectrumFastBinStarts[index]))
                let fastB1 = max(fastB0 + 1, min(fastHalf, spectrumFastBinEnds[index]))
                fastEnergy = spectrumEnergy(magnitudes: fastMagnitudes, b0: fastB0, b1: fastB1, peakWeight: peakWeight)
            } else {
                fastEnergy = longEnergy
            }

            let fastWeight = lowLatencySpectrumEnabled ? spectrumFastWeights[index] : 0
            let energy = max(longEnergy * (1 - fastWeight) + fastEnergy * fastWeight, 1e-12)
            let rawDb = 10 * log10(energy)
            let tiltedDb = rawDb + spectrumTiltsDb[index]

            let floorDb: Float = -88
            let topDb: Float = -10
            let linear = max(0, min(1, (tiltedDb - floorDb) / (topDb - floorDb)))
            let normalized = pow(linear, 1.35)
            spectrumRawBars[index] = normalized
        }

        if spectrumDisplayBars.count != spectrumBarCount {
            spectrumDisplayBars = [Float](repeating: 0, count: spectrumBarCount)
        }

        for index in 0..<spectrumBarCount {
            let incoming = spectrumRawBars[index]
            let previous = spectrumDisplayBars[index]
            // Frequency-dependent release: bass stays stable, treble decays fast.
            // Constants derived from analysis frame rate (~187 Hz at 48k/256):
            //   0.58 → ~68ms to -30 dB   (bass)
            //   0.40 → ~32ms to -30 dB   (mid)
            //   0.16 → ~20ms to -30 dB   (treble)
            let bassRelease: Float  = 0.58
            let trebleRelease: Float = 0.16
            let t = Float(index) / Float(max(1, spectrumBarCount - 1))
            let bandRelease = bassRelease + (trebleRelease - bassRelease) * t
            let decayed = previous * bandRelease
            spectrumDisplayBars[index] = incoming >= previous ? incoming : max(incoming, decayed)
        }

        return spectrumDisplayBars
    }

    private func spectrumEnergy(magnitudes: [Float], b0: Int, b1: Int, peakWeight: Float) -> Float {
        var peak: Float = 0
        var sum: Float = 0
        for bin in b0..<b1 {
            let value = magnitudes[bin]
            peak = max(peak, value)
            sum += value
        }
        let avg = sum / Float(max(1, b1 - b0))
        return max(peak * peakWeight + avg * (1 - peakWeight), 1e-12)
    }

    private func computeBandLevels(magnitudes: [Float]) -> [Float] {
        let half = magnitudes.count
        let binsPerHz = Float(fftSize) / sampleRate
        let freqBands: [(Float, Float)] = [(20, 250), (251, 5000), (5001, 20000)]
        for (index, band) in freqBands.enumerated() {
            let (low, high) = band
            let b0 = max(0, min(half - 1, Int(low * binsPerHz)))
            let b1 = max(0, min(half, Int(high * binsPerHz)))
            guard b1 > b0 else {
                bandLevelScratch[index] = Float(b0 == b1 && b0 < half ? magnitudes[b0] : 0)
                continue
            }
            var sum: Float = 0
            for i in b0..<b1 { sum += magnitudes[i] }
            let avg = sum / Float(b1 - b0)
            let db = 10 * log10(max(1e-12, avg))
            let floorDb: Float = -82
            let topDb: Float = -24
            bandLevelScratch[index] = max(0, min(1, (db - floorDb) / (topDb - floorDb)))
        }
        return bandLevelScratch
    }

    private func updateScrollingWaveform(samples: [Float], count: Int) -> [[Float]] {
        guard count > 0 else { return waveformHistoryBands }

        for index in 0..<count {
            let sample = samples[index]
            let signedSample = max(-1, min(1, sample))

            // Two-pole (12 dB/oct) lowpass filters. Low color bands are narrow
            // so red only represents true sub energy instead of broad bass bleed.
            lowpass80State  += lowpass80Alpha  * (sample - lowpass80State)
            lowpass80State2 += lowpass80Alpha  * (lowpass80State - lowpass80State2)
            lowpass250State  += lowpass250Alpha  * (sample - lowpass250State)
            lowpass250State2 += lowpass250Alpha  * (lowpass250State - lowpass250State2)
            lowpass400State  += lowpass400Alpha  * (sample - lowpass400State)
            lowpass400State2 += lowpass400Alpha  * (lowpass400State - lowpass400State2)
            lowpass1300State += lowpass1300Alpha * (sample - lowpass1300State)
            lowpass1300State2 += lowpass1300Alpha * (lowpass1300State - lowpass1300State2)
            lowpass5000State += lowpass5000Alpha * (sample - lowpass5000State)
            lowpass5000State2 += lowpass5000Alpha * (lowpass5000State - lowpass5000State2)

            let redSample    = lowpass80State2
            let orangeSample = lowpass250State2 - lowpass80State2
            let yellowSample = lowpass400State2 - lowpass250State2
            let greenSample  = lowpass1300State2 - lowpass400State2
            let cyanSample   = lowpass5000State2 - lowpass1300State2
            let blueSample   = sample - lowpass5000State2

            waveformBucketPeaks[0] = max(waveformBucketPeaks[0], waveformAmplitude(redSample, gain: 1))
            waveformBucketPeaks[1] = max(waveformBucketPeaks[1], waveformAmplitude(orangeSample, gain: 1))
            waveformBucketPeaks[2] = max(waveformBucketPeaks[2], waveformAmplitude(yellowSample, gain: 1))
            waveformBucketPeaks[3] = max(waveformBucketPeaks[3], waveformAmplitude(greenSample, gain: 1))
            waveformBucketPeaks[4] = max(waveformBucketPeaks[4], waveformAmplitude(cyanSample, gain: 1))
            waveformBucketPeaks[5] = max(waveformBucketPeaks[5], waveformAmplitude(blueSample, gain: 1))
            waveformBucketPositive = max(waveformBucketPositive, signedSample)
            waveformBucketNegative = min(waveformBucketNegative, signedSample)
            waveformBucketFrames += 1

            if waveformBucketFrames >= framesPerWaveformPoint {
                appendWaveformPoint(
                    waveformBucketPeaks,
                    positive: waveformBucketPositive,
                    negative: waveformBucketNegative
                )
                for band in waveformBucketPeaks.indices {
                    waveformBucketPeaks[band] = 0
                }
                waveformBucketPositive = 0
                waveformBucketNegative = 0
                waveformBucketFrames = 0
            }
        }

        waveformScrollPhase = Float(waveformBucketFrames) / Float(max(1, framesPerWaveformPoint))
        return waveformHistoryBands
    }

    private func onePoleAlpha(cutoff: Float) -> Float {
        1 - exp(-2 * .pi * cutoff / max(1, sampleRate))
    }

    private func configureAnalysis(for rate: Float) {
        let safeRate = max(1, rate)
        // Two-pole cascade shifts the -3 dB point down by ~0.644×.
        // Compensate cutoff frequencies so the effective -3 dB stays at the target.
        let compensate: Float = 1.0 / 0.644  // ≈ 1.553
        lowpass80Alpha   = 1 - exp(-2 * .pi * (80   * compensate) / safeRate)
        lowpass250Alpha  = 1 - exp(-2 * .pi * (250  * compensate) / safeRate)
        lowpass400Alpha  = 1 - exp(-2 * .pi * (400  * compensate) / safeRate)
        lowpass1300Alpha = 1 - exp(-2 * .pi * (1300 * compensate) / safeRate)
        lowpass5000Alpha = 1 - exp(-2 * .pi * (5000 * compensate) / safeRate)
        // Goniometer band filter alphas (two-pole)
        gonLowAlpha = 1 - exp(-2 * .pi * (250 * compensate) / safeRate)
        gonMidAlpha = 1 - exp(-2 * .pi * (5000 * compensate) / safeRate)
        framesPerWaveformPoint = max(32, Int(safeRate / 110))
        configureSpectrumMapping(for: safeRate)
    }

    private func configureSpectrumMapping(for rate: Float) {
        let safeRate = max(1, rate)
        let nyquist = min(safeRate * 0.5, 20_000)
        let minHz: Float = 30
        let maxHz = max(minHz + 1, nyquist)
        let logMin = log10(minHz)
        let logMax = log10(maxHz)
        let longHalf = fftSize / 2
        let fastHalf = fastFFTSize / 2

        for index in 0..<spectrumBarCount {
            let t0 = Float(index) / Float(spectrumBarCount)
            let t1 = Float(index + 1) / Float(spectrumBarCount)
            let f0 = pow(10, logMin + (logMax - logMin) * t0)
            let f1 = pow(10, logMin + (logMax - logMin) * t1)
            let longB0 = max(1, min(longHalf - 1, Int(f0 * Float(fftSize) / safeRate)))
            let longB1 = max(longB0 + 1, min(longHalf, Int(f1 * Float(fftSize) / safeRate)))
            let fastB0 = max(1, min(fastHalf - 1, Int(f0 * Float(fastFFTSize) / safeRate)))
            let fastB1 = max(fastB0 + 1, min(fastHalf, Int(f1 * Float(fastFFTSize) / safeRate)))
            let centerHz = sqrt(f0 * f1)
            let t = Float(index) / Float(max(1, spectrumBarCount - 1))

            spectrumLongBinStarts[index] = longB0
            spectrumLongBinEnds[index] = longB1
            spectrumFastBinStarts[index] = fastB0
            spectrumFastBinEnds[index] = fastB1
            // Peak weighting: how much the peak bin contributes vs. the band average.
            // Below 5 kHz: modest peak blend (34%→64%). Above 5 kHz: aggressive
            // peak weighting (80%→90%) so sparse hi-hat energy isn't averaged away
            // across wide log bands.
            if centerHz > 5000 {
                spectrumPeakWeights[index] = 0.80 + 0.10 * min(1, (centerHz - 5000) / 15000)
            } else {
                spectrumPeakWeights[index] = 0.34 + 0.30 * pow(t, 1.15)
            }
            spectrumFastWeights[index] = smoothstep(edge0: 260, edge1: 900, value: centerHz)

            // Display tilt in dB space. Keep bass honest without burying it:
            // the old -30 dB+ sub cut made real low end look absent.
            let octavesFromReference = log2(max(1, centerHz) / 1_000)
            let tiltDbPerOctave: Float = octavesFromReference < 0 ? 3.2 : 2.6
            let tiltDb = tiltDbPerOctave * octavesFromReference + spectrumColorBiasDb(for: centerHz)
            spectrumTiltsDb[index] = max(-16, min(12, tiltDb))
        }

        spectrumMappingSampleRate = safeRate
    }

    private func spectrumColorBiasDb(for frequency: Float) -> Float {
        let stops: [(hz: Float, db: Float)] = [
            (55, 0),
            (160, 0),
            (350, 0),
            (850, 0),
            (2_600, 0),
            (10_000, 0)
        ]
        let logHz = log2(max(1, frequency))

        if logHz <= log2(stops[0].hz) {
            return stops[0].db
        }

        for index in 0..<(stops.count - 1) {
            let lower = stops[index]
            let upper = stops[index + 1]
            let lowerLog = log2(lower.hz)
            let upperLog = log2(upper.hz)
            guard logHz <= upperLog else { continue }
            let t = max(0, min(1, (logHz - lowerLog) / (upperLog - lowerLog)))
            return lower.db + (upper.db - lower.db) * t
        }

        return stops[stops.count - 1].db
    }

    private func smoothstep(edge0: Float, edge1: Float, value: Float) -> Float {
        let x = max(0, min(1, (value - edge0) / max(1e-6, edge1 - edge0)))
        return x * x * (3 - 2 * x)
    }

    private func appendWaveformPoint(_ point: [Float], positive: Float, negative: Float) {
        if waveformHistoryBands.count != 6 {
            waveformHistoryBands = [[], [], [], [], [], []]
        }

        for band in 0..<6 {
            waveformHistoryBands[band].append(point[band])
            if waveformHistoryBands[band].count > waveformPointCount {
                waveformHistoryBands[band].removeFirst(waveformHistoryBands[band].count - waveformPointCount)
            }
        }

        waveformPositiveHistory.append(max(0, min(1, positive)))
        waveformNegativeHistory.append(min(0, max(-1, negative)))
        if waveformPositiveHistory.count > waveformPointCount {
            waveformPositiveHistory.removeFirst(waveformPositiveHistory.count - waveformPointCount)
        }
        if waveformNegativeHistory.count > waveformPointCount {
            waveformNegativeHistory.removeFirst(waveformNegativeHistory.count - waveformPointCount)
        }
    }

    private func waveformAmplitude(_ value: Float, gain: Float) -> Float {
        max(0, min(1, abs(value) * gain))
    }

    private func recordDroppedTap() {
        guard latencyProbesEnabled else { return }
        latencyProbeState.withLock { $0.droppedTaps += 1 }
    }

    private func recordCoalescedPublish() {
        guard latencyProbesEnabled else { return }
        latencyProbeState.withLock { $0.coalescedPublishes += 1 }
    }

    private func recordEnqueuedSnapshot() {
        guard latencyProbesEnabled else { return }
        latencyProbeState.withLock { $0.enqueuedSnapshots += 1 }
    }

    private func recordDisplayTick(scheduled: Bool) {
        guard latencyProbesEnabled else { return }
        latencyProbeState.withLock {
            $0.displayTicks += 1
            if scheduled {
                $0.displaySchedules += 1
            } else {
                $0.displaySkips += 1
            }
        }
    }

    private func recordRenderFrame() {
        guard latencyProbesEnabled else { return }
        latencyProbeState.withLock { $0.renderFrames += 1 }
    }

    private func recordPublish(snapshot: AnalyzerSnapshot, mainTimeNs: UInt64) {
        guard latencyProbesEnabled else { return }
        let report = latencyProbeState.withLock { state in
            state.recordPublish(snapshot: snapshot, mainTimeNs: mainTimeNs)
        }
        if let report {
            print(report)
        }
    }

    private func computeCorrelation(l: UnsafePointer<Float>, r: UnsafePointer<Float>, count: Int) -> Float {
        let n = min(count, 2048)
        var cov: Float = 0
        // Simplified: cosine similarity of zero-mean signals
        var lMean: Float = 0, rMean: Float = 0
        vDSP_meanv(l, 1, &lMean, vDSP_Length(n))
        vDSP_meanv(r, 1, &rMean, vDSP_Length(n))
        var negLMean = -lMean
        var negRMean = -rMean
        vDSP_vsadd(l, 1, &negLMean, &correlationLeftZero, 1, vDSP_Length(n))
        vDSP_vsadd(r, 1, &negRMean, &correlationRightZero, 1, vDSP_Length(n))
        vDSP_dotpr(correlationLeftZero, 1, correlationRightZero, 1, &cov, vDSP_Length(n))
        var lv: Float = 0, rv: Float = 0
        vDSP_dotpr(correlationLeftZero, 1, correlationLeftZero, 1, &lv, vDSP_Length(n))
        vDSP_dotpr(correlationRightZero, 1, correlationRightZero, 1, &rv, vDSP_Length(n))
        let denom = sqrt(lv * rv)
        return denom > 0 ? max(-1, min(1, cov / denom)) : 0
    }

    private func computeCorrelation(left: [Float], right: [Float], count: Int) -> Float {
        let n = min(count, left.count, right.count, 512)
        guard n > 0 else { return 0 }
        return left.withUnsafeBufferPointer { lbuf in
            right.withUnsafeBufferPointer { rbuf in
                guard let l = lbuf.baseAddress, let r = rbuf.baseAddress else { return 0 }
                return computeCorrelation(l: l, r: r, count: n)
            }
        }
    }

    private func computeCorrelation(left: [Float], right: [Float], offset: Int, count: Int) -> Float {
        let n = min(count, max(0, left.count - offset), max(0, right.count - offset), 512)
        guard n > 0 else { return 0 }
        return left.withUnsafeBufferPointer { lbuf in
            right.withUnsafeBufferPointer { rbuf in
                guard let l = lbuf.baseAddress, let r = rbuf.baseAddress else { return 0 }
                return computeCorrelation(l: l.advanced(by: offset), r: r.advanced(by: offset), count: n)
            }
        }
    }

    private func makeGoniometerPoints(left: [Float], right: [Float], count requestedCount: Int) -> [CGPoint] {
        let count = min(requestedCount, left.count, right.count)
        let step = max(1, count / 96)
        goniometerPointScratch.removeAll(keepingCapacity: true)
        for i in stride(from: 0, to: count, by: step) {
            goniometerPointScratch.append(CGPoint(x: CGFloat(left[i]), y: CGFloat(right[i])))
        }
        return goniometerPointScratch
    }

    private func makeGoniometerPoints(left: [Float], right: [Float], offset: Int, count requestedCount: Int) -> [CGPoint] {
        let count = min(requestedCount, max(0, left.count - offset), max(0, right.count - offset))
        let step = max(1, count / 96)
        goniometerPointScratch.removeAll(keepingCapacity: true)
        for i in stride(from: 0, to: count, by: step) {
            let index = offset + i
            goniometerPointScratch.append(CGPoint(x: CGFloat(left[index]), y: CGFloat(right[index])))
        }
        return goniometerPointScratch
    }

    // MARK: - Goniometer band processing helpers

    private func processGoniometerBand(
        left: [Float], right: [Float],
        offset: Int, count: Int,
        alpha: Float,
        leftState: inout Float, leftState2: inout Float,
        rightState: inout Float, rightState2: inout Float
    ) -> [CGPoint] {
        let n = min(count, left.count - offset, right.count - offset)
        let step = max(1, n / 96)
        var points: [CGPoint] = []
        points.reserveCapacity(n / step + 1)
        for i in stride(from: 0, to: n, by: step) {
            let idx = offset + i
            let l = left[idx]
            let r = right[idx]
            let fl = twoPoleLowpass(input: l, state: &leftState, state2: &leftState2, alpha: alpha)
            let fr = twoPoleLowpass(input: r, state: &rightState, state2: &rightState2, alpha: alpha)
            points.append(CGPoint(x: CGFloat(fl), y: CGFloat(fr)))
        }
        return points
    }

    private func processGoniometerBandHigh(
        left: [Float], right: [Float],
        offset: Int, count: Int,
        midLeft: Float, midRight: Float
    ) -> [CGPoint] {
        let n = min(count, left.count - offset, right.count - offset)
        let step = max(1, n / 96)
        var points: [CGPoint] = []
        points.reserveCapacity(n / step + 1)
        for i in stride(from: 0, to: n, by: step) {
            let idx = offset + i
            let rawL = left[idx]
            let rawR = right[idx]
            points.append(CGPoint(x: CGFloat(rawL - midLeft), y: CGFloat(rawR - midRight)))
        }
        return points
    }

    private func twoPoleLowpass(input: Float, state: inout Float, state2: inout Float, alpha: Float) -> Float {
        state += alpha * (input - state)
        state2 += alpha * (state - state2)
        return state2
    }

    deinit {
        removeTap()
        vDSP_destroy_fftsetup(fftSetup)
        vDSP_destroy_fftsetup(fastFFTSetup)
    }
}
