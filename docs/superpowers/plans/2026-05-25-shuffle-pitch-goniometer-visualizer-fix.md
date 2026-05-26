# Shuffle, Pitch, Goniometer & Visualizer Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add shuffle + repeat playback controls, pitch shifting knob, multiband dot goniometer, and fix the blank visualizer bug.

**Architecture:** Four independent features sharing the playback pipeline. Pitch adds `AVAudioUnitTimePitch` to the audio graph. Shuffle/repeat modify queue logic in `PlayerState`/`PlaybackController`. Goniometer adds per-band sample processing in `RealtimeAnalyzer`. Visualizer fix shores up display-link lifecycle timing.

**Tech Stack:** Swift + SwiftUI (macOS 14+), AVFAudio, Accelerate, Zig audio decoder

---

### Task 1: Pitch Knob — Audio Graph & State

**Files:**
- Modify: `AudioManager.swift` — add `AVAudioUnitTimePitch` node, reconnect graph, `setPitchShift()`
- Modify: `TemperPlayerApp.swift` — add `pitchShift` to `PlayerState`

**Steps:**

- [ ] **1.1: Add timePitchNode to AudioManager**

In `AudioManager`, add a new `AVAudioUnitTimePitch` node. In `init()`, attach and connect the chain as `playerNode → timePitchNode → mainMixerNode`:

```swift
// AudioManager.swift
private let timePitchNode = AVAudioUnitTimePitch()

// In init(), after attaching playerNode:
engine.attach(timePitchNode)
engine.connect(playerNode, to: timePitchNode, format: nil)
engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)
```

Add `@Published var pitchShift: Float = 0` and:

```swift
func setPitchShift(_ cents: Float) {
    let clamped = max(-2400, min(2400, cents))
    pitchShift = clamped
    timePitchNode.pitch = clamped
}
```

- [ ] **1.2: Add pitchShift to PlayerState**

In `TemperPlayerApp.swift` in `PlayerState`:

```swift
@Published var pitchShift: Float = 0
```

- [ ] **1.3: Wire pitch in PlaybackController**

Add to `PlaybackController`:

```swift
func setPitchShift(_ cents: Float) {
    let clamped = max(-2400, min(2400, cents))
    playerState.pitchShift = clamped
    audioManager.setPitchShift(clamped)
}
```

Also add `audioManager.setPitchShift(playerState.pitchShift)` in `startPreparedTrack()`.

- [ ] **1.4: Build and verify (no UI yet)**

### Task 2: Pitch Knob UI

**Files:**
- Modify: `TransportBar.swift`

**Steps:**

- [ ] **2.1: Add PitchKnobView to TransportBar**

Between the repeat button area and `backward.fill`, add a circular pitch knob. The knob is a thin circle stroke that rotates based on pitch value. Vertical drag changes pitch.

```swift
// TransportBar.swift — add before the backward.fill button

PitchKnobView(value: $playerState.pitchShift, range: -2400...2400)
    .frame(width: 16 * uiScale, height: 16 * uiScale)
```

Define `PitchKnobView` as a private struct in the same file:

```swift
private struct PitchKnobView: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    @State private var isDragging = false
    @State private var dragStartValue: Float = 0
    @Environment(\.uiScale) var uiScale

    private var rotation: Angle {
        .degrees(Double((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 270 - 135))
    }

    var body: some View {
        Circle()
            .stroke(isDragging ? Color.white : Color(white: 0.35), lineWidth: 1.5)
            .overlay(
                // Ticks or indicator
                Rectangle()
                    .fill(isDragging ? Color.white : Color(white: 0.35))
                    .frame(width: 1.5, height: 4)
                    .offset(y: -7)
                    .rotationEffect(rotation)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        let delta = Float(-v.translation.height) / 100
                        let range_float = range.upperBound - range.lowerBound
                        value = max(range.lowerBound, min(range.upperBound, dragStartValue + delta * range_float))
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
            }
    }
}
```

### Task 3: Shuffle + Repeat — State & Logic

**Files:**
- Modify: `TemperPlayerApp.swift` — PlayerState `isShuffled`, `repeatMode`, `originalQueue`, shuffle/restore methods
- Modify: `PlaybackController.swift` — `toggleShuffle()`, `cycleRepeatMode()`, modified playNext

**Steps:**

- [ ] **3.1: Add shuffle + repeat state to PlayerState**

```swift
// In PlayerState in TemperPlayerApp.swift

enum RepeatMode: Int { case off = 0, all, one }

@Published var isShuffled = false
@Published var repeatMode: RepeatMode = .off
private var originalQueue: [Track] = []
private var shuffledPlayedIndices: Set<Int> = []

func toggleShuffle() {
    isShuffled.toggle()
    if isShuffled {
        originalQueue = queue
        shuffleRemaining()
    } else {
        // Restore original order, preserve current track
        guard let current = currentTrack, let origIndex = originalQueue.firstIndex(where: { $0.id == current.id }) else {
            queue = originalQueue
            queueIndex = 0
            originalQueue = []
            return
        }
        queue = originalQueue
        queueIndex = origIndex
        originalQueue = []
    }
    shuffledPlayedIndices = []
}

private func shuffleRemaining() {
    guard let qi = queueIndex, qi + 1 < queue.count else { return }
    var rest = Array(queue[(qi + 1)...])
    rest.shuffle()
    queue = Array(queue[0...qi]) + rest
}

func cycleRepeatMode() {
    switch repeatMode {
    case .off: repeatMode = .all
    case .all: repeatMode = .one
    case .one: repeatMode = .off
    }
}
```

Override `prepareToPlay` to reset shuffle state when a new context is set (only reset if shuffle is currently on — re-shuffle the new queue):

```swift
// In prepareToPlay, after setting queue
if isShuffled {
    originalQueue = queue
    shuffleRemaining()
}
```

- [ ] **3.2: Modify advanceToNext for shuffle + repeat**

```swift
// Modified advanceToNext
func advanceToNext() -> Track? {
    ensureCurrentQueue()
    
    // Repeat one: replay current track
    if repeatMode == .one, let current = currentTrack {
        currentTime = 0
        return current
    }
    
    // No queue
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
    
    // End of queue — repeat all wraps around
    if repeatMode == .all {
        if isShuffled {
            // Re-shuffle everything
            originalQueue = queue
            queue = queue.shuffled()
            queueIndex = 0
        } else {
            queueIndex = 0
        }
        let next = queue[0]
        setCurrent(next)
        return next
    }
    
    return nil // End of queue, no repeat
}
```

- [ ] **3.3: PlaybackController methods**

```swift
func toggleShuffle() {
    playerState.toggleShuffle()
}

func cycleRepeatMode() {
    playerState.cycleRepeatMode()
}
```

Modify `playNextAfterFinish()` for repeat one:

```swift
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
```

### Task 4: Shuffle + Repeat — UI Buttons

**Files:**
- Modify: `TransportBar.swift`

**Steps:**

- [ ] **4.1: Add shuffle and repeat buttons**

Replace the start of the transport button group:

```swift
// Right before backward.fill, after the Spacer in the button HStack:
shuffleButton
repeatButton
PitchKnobView(...)  // (from Task 2)
transportButton(systemName: "backward.fill") { playback.previous() }
// ... rest of existing buttons
```

Add button helpers:

```swift
private var shuffleButton: some View {
    Button(action: { playback.toggleShuffle() }) {
        Image(systemName: "shuffle")
            .font(.system(size: 8 * uiScale, weight: .medium))
            .foregroundStyle(playerState.isShuffled ? Color(red: 0.3, green: 0.8, blue: 0.4) : .tertiary)
    }
    .buttonStyle(.plain)
}

private var repeatButton: some View {
    Button(action: { playback.cycleRepeatMode() }) {
        Image(systemName: repeatIconName)
            .font(.system(size: 8 * uiScale, weight: .medium))
            .foregroundStyle(repeatColor)
    }
    .buttonStyle(.plain)
}

private var repeatIconName: String {
    switch playerState.repeatMode {
    case .off: return "repeat"
    case .all: return "repeat"
    case .one: return "repeat.1"
    }
}

private var repeatColor: Color {
    switch playerState.repeatMode {
    case .off: return .tertiary
    case .all, .one: return Color(red: 0.3, green: 0.8, blue: 0.4)
    }
}
```

### Task 5: Goniometer — Per-Band Sample Processing

**Files:**
- Modify: `RealtimeAnalyzer.swift` — add 3-band filter states for L/R, per-band goniometer points

**Steps:**

- [ ] **5.1: Add band filter states and ring buffers**

In the existing filter section of `RealtimeAnalyzer`, add per-band left/right lowpass states:

```swift
// Per-band goniometer filter states (left channel)
private var gonLowLeftState: Float = 0, gonLowLeftState2: Float = 0
private var gonMidLeftState: Float = 0, gonMidLeftState2: Float = 0
private var gonHighLeftState: Float = 0, gonHighLeftState2: Float = 0
// Right channel
private var gonLowRightState: Float = 0, gonLowRightState2: Float = 0
private var gonMidRightState: Float = 0, gonMidRightState2: Float = 0
private var gonHighRightState: Float = 0, gonHighRightState2: Float = 0
// Two-pole alphas (computed in configureAnalysis)
private var gonLowAlpha: Float = 0, gonMidAlpha: Float = 0, gonHighAlpha: Float = 0
```

Add ring buffers:

```swift
private var goniometerBassSamples: [CGPoint] = []
private var goniometerMidSamples: [CGPoint] = []
private var goniometerHighSamples: [CGPoint] = []
private let maxGoniometerSamples = 720
```

- [ ] **5.2: Compute per-band alphas in configureAnalysis**

```swift
// In configureAnalysis, after existing lowpass alphas:
let gonLowCompensate: Float = 250 * compensate
let gonMidCenter: Float = 2000
let gonHighCompensate: Float = 5000 * compensate
gonLowAlpha = 1 - exp(-2 * .pi * gonLowCompensate / safeRate)
gonMidAlpha = 1 - exp(-2 * .pi * gonMidCenter / safeRate)
gonHighAlpha = 1 - exp(-2 * .pi * gonHighCompensate / safeRate)
```

- [ ] **5.3: Process per-band points in processCopiedSamples**

In `processCopiedSamples`, after the existing two-pole filtering for waveform, add per-channel band filtering and goniometer point generation.

When `hasRight` is true, process each band on left and right channels separately. The exact approach: apply two-pole lowpass at 250 Hz to get bass, apply bandpass filter around 2kHz for mid, apply highpass (subtract lowpass) above 5kHz for high.

Actually, let me re-think. We already have `captureLeft` and `captureRight` buffers with raw samples. We need to filter them by band and create goniometer points from the filtered pairs.

The simplest approach that matches the user's intent: for each analysis chunk, run the existing `makeGoniometerPoints` but first filter each channel through three band filters:

```swift
// Instead of using the raw captureLeft/captureRight for the goniometer,
// create filtered copies and generate per-band points.
// This replaces the existing goniometer generation in processCopiedSamples.
```

Let me think about this more carefully. The current code generates goniometer points from raw left/right samples in `makeGoniometerPoints(left:right:offset:count:)`. For the multiband version, I need to filter `captureLeft` and `captureRight` into three bands each, then generate points from the filtered pairs.

The bands should use two-pole lowpass/highpass just like the waveform:

Low band: 2-pole lowpass at 250 Hz on L and R individually
Mid band: bandpass (highpass at 250 - lowpass at 5000)
High band: 2-pole highpass at 5000 Hz on L and R individually

I'll add the filtering directly in `processCopiedSamples`, right after the existing waveform filtering. For each sample in the chunk, I run L and R through the band filters and accumulate points into per-band arrays.

Let me update the AnalyzerSnapshot to include the new point arrays:

```swift
// New snapshot fields
let goniometerBassPoints: [CGPoint]
let goniometerMidPoints: [CGPoint]
let goniometerHighPoints: [CGPoint]
// Published
private(set) var goniometerBassPoints: [CGPoint] = []
private(set) var goniometerMidPoints: [CGPoint] = []
private(set) var goniometerHighPoints: [CGPoint] = []
```

Reset in `reset()`. Smooth in `publishSnapshot`. I won't smooth the goniometer points — they're already naturally smoothed by the display pacing.

Actually, for the goniometer the current approach keeps a ring buffer of points and publishes the entire buffer. The smooth happens naturally because points accumulate. I'll follow the same pattern but with 3 separate ring buffers.

- [ ] **5.4: Update AnalyzerSnapshot and published state**

Add to `AnalyzerSnapshot` struct:
```swift
let goniometerBassPoints: [CGPoint]
let goniometerMidPoints: [CGPoint]
let goniometerHighPoints: [CGPoint]
```

Add published properties:
```swift
private(set) var goniometerBassPoints: [CGPoint] = []
private(set) var goniometerMidPoints: [CGPoint] = []
private(set) var goniometerHighPoints: [CGPoint] = []
```

Update `publishSnapshot`:
```swift
goniometerBassPoints = snapshot.goniometerBassPoints
goniometerMidPoints = snapshot.goniometerMidPoints
goniometerHighPoints = snapshot.goniometerHighPoints
```

Update `reset()`:
```swift
goniometerBassPoints = []
goniometerMidPoints = []
goniometerHighPoints = []
```

- [ ] **5.5: Band filtering and point generation**

In `processCopiedSamples`, add 3-band goniometer processing when `hasRight` is true:

```swift
if hasRight {
    // Apply band filters to left/right samples and generate per-band points
    let bassPoints = processGoniometerBand(
        left: captureLeft, right: captureRight,
        offset: offset, count: len,
        bandAlpha: gonLowAlpha,
        leftState: &gonLowLeftState, leftState2: &gonLowLeftState2,
        rightState: &gonLowRightState, rightState2: &gonLowRightState2
    )
    let midPoints = processGoniometerBand(
        left: captureLeft, right: captureRight,
        offset: offset, count: len,
        bandAlpha: gonMidAlpha,
        leftState: &gonMidLeftState, leftState2: &gonMidLeftState2,
        rightState: &gonMidRightState, rightState2: &gonMidRightState2
    )
    let highPoints = processGoniometerBandHigh(
        left: captureLeft, right: captureRight,
        offset: offset, count: len
    )
    
    if !bassPoints.isEmpty {
        goniometerBassSamples.append(contentsOf: bassPoints)
        if goniometerBassSamples.count > maxGoniometerSamples {
            goniometerBassSamples.removeFirst(goniometerBassSamples.count - maxGoniometerSamples)
        }
    }
    // Same for mid and high
}
```

Add the helper methods:

```swift
private func processGoniometerBand(
    left: [Float], right: [Float],
    offset: Int, count: Int,
    bandAlpha: Float,
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
        let fl = twoPoleLowpass(input: l, state: &leftState, state2: &leftState2, alpha: bandAlpha)
        let fr = twoPoleLowpass(input: r, state: &rightState, state2: &rightState2, alpha: bandAlpha)
        points.append(CGPoint(x: CGFloat(fl), y: CGFloat(fr)))
    }
    return points
}

private func processGoniometerBandHigh(
    left: [Float], right: [Float],
    offset: Int, count: Int
) -> [CGPoint] {
    let n = min(count, left.count - offset, right.count - offset)
    let step = max(1, n / 96)
    var points: [CGPoint] = []
    points.reserveCapacity(n / step + 1)
    for i in stride(from: 0, to: n, by: step) {
        let idx = offset + i
        points.append(CGPoint(x: CGFloat(left[idx] - gonLowLeftState2), y: CGFloat(right[idx] - gonLowRightState2)))
    }
    return points
}

private func twoPoleLowpass(input: Float, state: inout Float, state2: inout Float, alpha: Float) -> Float {
    state += alpha * (input - state)
    state2 += alpha * (state - state2)
    return state2
}
```

But wait — the existing waveform filtering already uses two-pole lowpass for band separation with subtraction. For the goniometer, I should use a similar approach. The `gonMidAlpha` bandpass is trickier. 

Actually, for simplicity and consistency with the existing code, let me use the same band-splitting technique as the waveform:

- **Low**: two-pole lowpass at 250 Hz → L and R values → (x, y) = (filteredL, filteredR)
- **Mid**: two-pole lowpass at 5000 Hz minus low at 250 Hz → bandpass
- **High**: original sample minus two-pole lowpass at 5000 Hz → highpass

I need 4 filter states per channel (lowpass250, lowpass5000), and each accumulates both primary and secondary states.

Actually, to keep it simpler: I already have lowpass250 and lowpass5000 states with their stage2 variants from the waveform processing. But those are running on the *mix* (L+R)/2, not on individual channels.

For the goniometer I need L and R individually. So I'll add dedicated filter states.

Let me simplify: just add dedicated two-pole filter states for the goniometer bands (L and R channels), using the same two-pole approach.

Actually, re-reading the code more carefully, the waveform filtering in `updateScrollingWaveform` operates on the mixed mono signal (`mixScratch`), not individual channels. For the goniometer I need independent L/R processing.

Let me add 6 filter state pairs (3 bands × 2 channels):

```
gonLowL, gonLowL2, gonLowR, gonLowR2  — lowpass 250 Hz
gonMidL, gonMidL2, gonMidR, gonMidR2  — lowpass 5000 Hz (mid = midLowpass - lowLowpass)  
// high = raw - lowpass5000 — no filter state needed
```

Wait, actually for high band I can compute it as: high = original_sample - mid_lowpass_output. But the mid lowpass is on the individual L/R channels. Let me just track it.

Better approach: 3 two-pole filters per channel, each at a different cutoff:
- Low: two-pole at 250 Hz
- Mid: two-pole at 5000 Hz (then subtract low output to get 250-5000 bandpass)
- High: raw input minus two-pole at 5000 Hz

So I need 4 filter states per channel (lowpass250 × 2 stages, lowpass5000 × 2 stages) = 8 total:

```
lowL, lowL2 (lowpass 250 L)
lowR, lowR2 (lowpass 250 R)
midL, midL2 (lowpass 5000 L)  
midR, midR2 (lowpass 5000 R)
```

Then:
- bass = (lowL2, lowR2)
- mid = (midL2 - lowL2, midR2 - lowR2) 
- high = (rawL - midL2, rawR - midR2)

This is clean and consistent. Let me use this.

Update AnalyzerSnapshot:

```swift
let goniometerBassPoints: [CGPoint]
let goniometerMidPoints: [CGPoint]
let goniometerHighPoints: [CGPoint]
```

### Task 6: Goniometer — View

**Files:**
- Modify: `MultibandViews.swift` — rewrite `MBGoniometerView`

**Steps:**

- [ ] **6.1: Rewrite MBGoniometerView**

Replace the current Canvas content. Keep the outer frame (VStack with "GONIO" label). Replace the Canvas drawing to render three dot clouds with additive blend:

```swift
// Inside Canvas in MBGoniometerView:
let bassPoints = analyzer.goniometerBassPoints
let midPoints = analyzer.goniometerMidPoints
let highPoints = analyzer.goniometerHighPoints

// Background circle + crosshairs (same as before)

// Draw each band as dots with additive blend
func drawDotCloud(_ points: [CGPoint], color: Color, radius: CGFloat, in context: inout GraphicsContext) {
    guard !points.isEmpty else { return }
    let scale = radius * 0.92
    for pt in points {
        let left = max(-1, min(1, pt.x))
        let right = max(-1, min(1, pt.y))
        let mid = (left + right) * 0.5
        let side = (left - right) * 0.5
        let dx = side * scale
        let dy = mid * scale
        guard hypot(dx, dy) <= radius else { continue }
        let x = center.x + dx
        let y = center.y - dy
        context.fill(
            Path(ellipseIn: CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)),
            with: .color(color.opacity(0.35))
        )
    }
}

// Draw using additive blend
context.blendMode = .screen
drawDotCloud(bassPoints, color: Color(red: 1, green: 0, blue: 0), radius: radius, in: &context)  // bass = red
drawDotCloud(midPoints, color: Color(red: 0, green: 1, blue: 0), radius: radius, in: &context)    // mid = green
drawDotCloud(highPoints, color: Color(red: 0.2, green: 0.4, blue: 1), radius: radius, in: &context) // high = blue
context.blendMode = .normal
```

### Task 7: Visualizer Blank Bug Fix

**Files:**
- Modify: `AudioManager.swift` — safer stop/play ordering
- Modify: `RealtimeAnalyzer.swift` — guard in publishDisplayOnlyFrame

- [ ] **7.1: Safer engine reset in AudioManager.stop()**

In `stop()`, add `engine.reset()` after `playerNode.stop()`:

```swift
func stop() {
    playbackGeneration += 1
    finishNotified = true
    analyzer.removeTap()
    analyzer.reset()
    playerNode.stop()
    engine.reset()  // ← ADD THIS
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
```

- [ ] **7.2: Guard in publishDisplayOnlyFrame**

In `publishDisplayOnlyFrame`, return early if the analyzer was just reset and has no data:

```swift
private func publishDisplayOnlyFrame(elapsedSeconds: Double) {
    guard !isFrozen, !waveformBands.isEmpty, !waveformBands[0].isEmpty else {
        return  // No data to render — skip
    }
    // ... rest of existing method
}
```

### Task 8: Build & Test

- [ ] **8.1: Build the project**

```bash
cd /Users/achumukundan/workspace/git/temperplayer && swift build --package-path TemperPlayer
```

- [ ] **8.2: Run and test manually**

Check:
1. Shuffle button toggles on/off, queue randomizes
2. Repeat mode cycles off → all → one → off
3. Repeat one loops current track
4. Repeat all wraps around queue
5. Pitch knob responds to vertical drag, double-click resets
6. Goniometer shows 3 colored dot clouds with additive blend
7. Rapid manual track changes don't blank the visualizer
