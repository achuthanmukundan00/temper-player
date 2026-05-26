# TemperPlayer: Shuffle, Pitch, Goniometer, & Visualizer Fix

## 1. Goniometer — Multiband Additive Dot Cloud

### Current state
`MBGoniometerView` draws a single continuous line trace from raw left/right samples. The trace is monochrome (green or red based on correlation).

### Design
Render three separate **dot clouds** on the goniometer canvas, one per frequency band (bass, mid, high). Each cloud is drawn as tiny circles at each sample point's mapped (x, y) position.

### Band splitting
The analyzer already computes three band levels (20–250 Hz, 251–5000 Hz, 5001–20000 Hz). For the goniometer, we need per-band left/right sample pairs. This requires:
- Three new filter pairs in `RealtimeAnalyzer.processCopiedSamples` (left/right for each band)
- A lowpass at 250 Hz, a bandpass 251–5000 Hz, and a highpass at 5001 Hz
- Each produces separate (L, R) → (x, y) point sequences

### Rendering
- **Bass (20–250 Hz):** `Color(red: 1.0, green: 0.0, blue: 0.0)` — tiny dots (radius ~1.2), opacity varies with amplitude
- **Mid (251–5000 Hz):** `Color(red: 0.0, green: 1.0, blue: 0.0)` — tiny dots (radius ~1.0)
- **High (5001+ Hz):** `Color(red: 0.0, green: 0.3, blue: 1.0)` — tiny dots (radius ~0.8)

Additive blend mode so overlapping bands produce secondary colors (yellow = bass+mid, magenta = bass+high, cyan = mid+high).

### Ring buffer per band
Each band maintains its own ring buffer of `[CGPoint]` (max ~720 points). On each analyzer snapshot publish, all three are sent to the view.

### File changes
- `RealtimeAnalyzer.swift` — add three filter states, per-band goniometer point computation, new snapshot fields `goniometerBassPoints`, `goniometerMidPoints`, `goniometerHighPoints`, new published properties
- `MultibandViews.swift` — rewrite `MBGoniometerView` to render three dot clouds with additive blend

---

## 2. Pitch Shifting — Circular Knob

### Implementation
Use `AVAudioUnitTimePitch` inserted into the audio engine chain:
- Create an `AVAudioUnitTimePitch` node between `playerNode` and `mainMixerNode`
- `pitch` property maps: knob value (0.0–1.0) → pitch shift in cents (-2400 to +2400)
- Default at knob center (0.5) = 0 cents; min = -2400c; max = +2400c

### UI: Circular knob in TransportBar
- Position: left of `backward.fill` button
- Visual: circle stroke (not filled), flat style, ~16×16pt
- Interaction: vertical drag gesture on the knob changes pitch
  - Drag up = increase pitch, drag down = decrease
  - The knob visual rotates to indicate current position
- Double-click / double-tap resets to 0 (center)
- A `@Published var pitchShift: Float` on `AudioManager` and `PlayerState`

### Audio graph changes
```swift
// Current:
playerNode → mainMixerNode

// New:
playerNode → timePitchNode → mainMixerNode
```

The time-pitch node defaults to `rate: 1.0` and `pitch: 0` — no audible effect by default.

### Reconnecting on each play call
`AVAudioUnitTimePitch` must be detached/reattached when the audio graph changes (on `stop()` and `setVolume()`). We need to:
- `engine.attach(timePitchNode)` in init
- During `play()`, reconnect: `engine.connect(playerNode, to: timePitchNode, format: nil)` then `engine.connect(timePitchNode, to: engine.mainMixerNode, format: nil)`
- During `stop()`, disconnect and reconnect playerNode directly to mainMixerNode temporarily? No — just keep the pitch node always in the chain. It's a pass-through when pitch=0.

### File changes
- `AudioManager.swift` — add `timePitchNode`, reconnect audio graph, `setPitchShift()` method
- `PlayerState` — add `pitchShift: Float` published property
- `TransportBar.swift` — add `PitchKnobView`

---

## 3. Shuffle + Repeat System

### Shuffle
- `PlayerState` gets `@Published var isShuffled: Bool`
- `PlaybackController` adds `toggleShuffle()` which calls `playerState.isShuffled.toggle()`
- When shuffle activates: shuffle the remaining queue (all tracks after the current index). Store the original queue order so it can be restored on deactivation.
- When shuffle deactivates: restore original queue order.
- When all remaining tracks have been played: re-shuffle the queue (excluding the just-finished track).
- `advanceToNext()` checks `isShuffled` and picks a random unplayed track.

### Repeat
- `PlayerState` gets `@Published var repeatMode: RepeatMode` enum: `.off`, `.all`, `.one`
- `PlaybackController` adds `cycleRepeatMode()` to advance through the three states.
- Repeat all: when `advanceToNext()` returns nil (end of queue), wrap back to start and continue.
- Repeat one: `playNextAfterFinish()` calls `startPreparedTrack(currentTrack)` instead of `advanceToNext()`. The player simply re-plays the current track from the beginning.

### Interaction: repeat_one + shuffle
When repeat one is active, it overrides shuffle — the current track just loops independently.

### Transport bar buttons
- Repeat button: cycles through three visual states — no highlight (off), "A" icon (repeat all), "1" icon (repeat one)
- Shuffle button: toggled highlight, "S" or shuffled-arrows SF Symbol icon

### File changes
- `PlayerState` — add `isShuffled`, `RepeatMode` enum, `repeatMode`, `originalQueue` backup
- `PlaybackController` — add `toggleShuffle()`, `cycleRepeatMode()`, modify `advanceToNext()` and `playNextAfterFinish()`
- `TransportBar.swift` — add shuffle button, repeat button

---

## 4. Visualizer Blank on Track Change

### Root cause hypothesis
When `stop()` is called on `AudioManager`, it calls `analyzer.removeTap()` and `analyzer.reset()`. Then `play()` calls `analyzer.reset()` again, `analyzer.installTap()`, and `startDisplayLink()`. There's a timing window where:

1. The new `installTap()` has been called, starting the display link
2. But no audio data has arrived through the tap yet
3. The display link fires `publishDisplayOnlyFrame()` which skips rendering when `waveformBands` is empty
4. If the user quickly triggers another track change before data arrives, the state gets tangled

Additionally, `reinstallTap()` in `AudioManager.play()` calls `removeTap()` then `installTap()` — but `engine.start()` may throw if the engine isn't properly reset from the previous track.

### Fix approach
1. **Ensure the display link is stopped BEFORE removeTap:** In `audioManager.play()`, call `reinstallTap()` but guarantee the display link fully stops before restarting.
2. **Add a guard in `publishDisplayOnlyFrame`:** If the analyzer has been reset but no waveform data exists yet AND the display link was just installed, skip the no-op publish entirely instead of publishing empty data.
3. **Engine restart safety:** In `playViaAVFoundation` and `playViaDecoder`, call `engine.reset()` and `engine.start()` in a safer sequence. Currently `stop()` calls `playerNode.stop()` but not `engine.reset()` — add that.
4. **Publish frame with data check:** In `publishQueuedVisualFrame`, if we pop a nil snapshot AND the waveform is empty, skip `publishDisplayOnlyFrame` entirely (return early).

### File changes
- `AudioManager.swift` — safer `stop()` with `engine.reset()`, order of operations in `play()`
- `RealtimeAnalyzer.swift` — guard in `publishDisplayOnlyFrame`, ensure display-link lifecycle is tied to tap installation

---

## Files Summary

| File | Changes |
|------|---------|
| `AudioManager.swift` | Add `AVAudioUnitTimePitch` node, reconnect audio graph, `setPitchShift()`, safer stop/play with `engine.reset()` |
| `RealtimeAnalyzer.swift` | Per-band goniometer filters, 3-band point ring buffers, new snapshot fields, guard in `publishDisplayOnlyFrame` |
| `PlayerState` (in `TemperPlayerApp.swift`) | Add `isShuffled`, `RepeatMode`, `repeatMode`, `pitchShift`, `originalQueue` backup |
| `PlaybackController.swift` | `toggleShuffle()`, `cycleRepeatMode()`, modified `advanceToNext()` and `playNextAfterFinish()`, pitch bridge |
| `TransportBar.swift` | Pitch knob view, shuffle toggle button, repeat mode cycle button |
| `MultibandViews.swift` | Rewrite `MBGoniometerView` with three-band additive dot rendering |
