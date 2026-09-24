# Changelog

## v0.2.0 — Library usability and reliability

- Import multiple files/folders or drops through one cancellable pipeline, with duplicate-path detection, playback validation, and explicit results.
- Add confirmed bulk library removal, folder rescans, and missing-file cleanup without deleting source audio.
- Add searchable artist/album actions, persistent sorting, range/multiple selection, empty-state onboarding, and library-only batch metadata editing.
- Complete playlist rename/clear/delete safeguards, bulk membership actions, and responsive controls.
- Add the full queue editor and fix shuffled edits, duplicate occurrences, current-track removal, end-of-queue replay, and failed-file loops.
- Make SQLite mutations transactional and checked; preserve history on reimport, handle 64-bit file sizes, and surface failures without publishing unsaved state.
- Make artwork/index writes atomic and preserve legacy artwork if migration cannot be saved.
- Reject surround audio instead of passing unwritten channels through the stereo pitch pipeline; mono and stereo remain supported.
- Add isolated regression tests, macOS CI, runtime dylib resolution for source builds/tests, a user guide, and release gates.
- Package a self-contained Apple-silicon DMG with version metadata, third-party notices, and SHA-256 checksums. This release is ad-hoc signed, not Developer ID signed or notarized.

See [v0.2.0 release notes](docs/releases/v0.2.0.md) for installation, validation, and known limitations.

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
