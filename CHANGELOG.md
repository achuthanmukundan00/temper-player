# Changelog

## v0.1.0 — Peak-Locked Phase Vocoder Pitch Engine

### 🎛️ Pitch shifting — rebuilt from scratch
- **Hand-rolled peak-locked phase vocoder in Zig** replacing Apple's `AVAudioUnitTimePitch`.
  The old unit sounded papery and harsh in the high end — like MP3 compression artifacts.
  The new engine uses identity phase locking (Laroche–Dolson), transient preservation,
  and Kaiser-windowed sinc resampling for transparent pitch shifting across ±1200 cents.
- **Mathematically transparent at 0 cents** — the entire chain is a no-op within
  float rounding error (verified at 3.1e-7 max error over 31k samples).
- **Peak locking keeps harmonics glued together** — no phasey/underwater artifacts.
- **Transient detection resets phases on attacks** — drums stay punchy, not smeared.
- **Stereo image preserved** — analysis decisions run on the mid signal so L/R never
  make conflicting phase choices.
- **76× realtime performance** on M-series — negligible CPU cost.

### 🔧 Fixes
- **Blackout on track switch**: `isFrozen` was stuck `true` after pause, silently
  dropping every visual frame on the next track. Now explicitly cleared on `play()`.
- **Pitch-shifted playback on certain sample rates**: the audio graph connected
  `playerNode → mainMixer` with `format: nil`, defaulting to the hardware output
  rate. 44.1 kHz files on 48 kHz systems played ~147 cents sharp. Now explicitly
  connected with the file's real processing format.
- **Double-flush glitch at EOF**: two buffers in flight both triggered EOF drain.
  Added generation guard so only the first pump flushes.

### ⚡ Visualizer
- **`bandCorrelations`** — per-band (bass/mid/high) Pearson correlation with
  goniometer-shared two-pole IIR bandpass filters, replacing the old tripled
  wideband correlation value.
- Blinking fix: goniometer filter states now properly reset on track change.
- Smoothing pipeline restored to original behavior — 90% visual smoothing
  across all published metrics.

---

**Download:** `TemperPlayer-v0.1.0.dmg` below.  
Drag to `/Applications` and launch. macOS may require right-click → Open on first run.
