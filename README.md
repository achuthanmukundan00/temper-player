<div align="center">
  <h1>TemperPlayer</h1>
  <p>A native macOS library player and audio-analysis workspace built with SwiftUI and Zig.</p>
  <p>
    <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple" alt="macOS 14 or newer">
    <img src="https://img.shields.io/badge/UI-SwiftUI-orange?logo=swift" alt="SwiftUI">
    <img src="https://img.shields.io/badge/DSP-Zig-yellow?logo=zig" alt="Zig DSP core">
    <img src="https://img.shields.io/badge/release-v0.2.0-blueviolet" alt="v0.2.0">
  </p>
  <img width="1280" height="720" alt="TemperPlayer library and visualization workspace" src="https://github.com/user-attachments/assets/21460c7f-2bb7-4c37-8a1f-e367e1821284" />
</div>

## What it does

TemperPlayer is a local music player for macOS. It combines a SwiftUI library and playback interface with a Zig core for FLAC/WAV inspection, mastering analysis, and real-time pitch processing.

- **Local library** — import files or folders, search and sort tracks, batch-edit library metadata, manage playlists, and maintain a play queue in SQLite.
- **Library management** — confirmed single/bulk removal, folder rescans, and missing-file cleanup. Original audio files are never deleted.
- **Reliable imports** — cancellable jobs, duplicate-path detection, validation, and a summary of imported, skipped, and failed files.
- **Native playback** — AVFoundation handles playback and Apple-supported compressed formats.
- **Supported imports** — mono/stereo FLAC, WAV, MP3, M4A, AAC, and MP4 audio.
- **Audio inspection** — waveform, scrolling spectrogram, mastering measurements, and multiband stereo correlation views.
- **Pitch control** — an identity-phase-locked phase vocoder in Zig with transient resets and Kaiser-windowed sinc resampling.
- **Menu-bar player** — track information and transport controls without keeping the main window open.
- **Responsive workspace** — compact playback surfaces through a larger library and visualization layout.

The current playback path uses AVFoundation for every supported format. The Zig decoder is used during import and analysis for FLAC and WAV; it does not add OGG or AIFF playback support.

## Using the app

Start with **Import** (⌘O), or drop audio files/folders into the window. Use the **Actions** menu for selected tracks, the folder/gear button for library management, and the list button for the full queue. Command-click selects multiple tracks; Shift-click selects a range in Files and Playlists.

See the [user guide](docs/user-guide.md) for deletion semantics, playlists, metadata, shortcuts, and backups. These improvements are included in v0.2.0.

## Download

Download `TemperPlayer-v0.2.0.dmg` and `SHA256SUMS` from the [v0.2.0 release](https://github.com/achuthanmukundan00/temper-player/releases/tag/v0.2.0). Verify with `shasum -a 256 -c SHA256SUMS`, then drag the app to Applications.

The download targets **Apple silicon** and requires **macOS 14 or newer**. It is **ad-hoc signed, not Developer ID signed or notarized**. macOS may block its first launch; only if you trust the download, approve it in **System Settings → Privacy & Security → Open Anyway**. Do not disable Gatekeeper globally. Back up `~/.temperplayer` before upgrading; replacing the app leaves your library and original audio files in place.

## Build from source

Prerequisites:

- macOS 14+
- Xcode 15+ / Swift 5.9+
- Zig 0.16.0

```bash
git clone https://github.com/achuthanmukundan00/temper-player.git
cd temper-player

cd zig-core
zig build -Dtarget=native --release=fast

cd ../TemperPlayer
swift build -c release
```

`Package.swift` links the Swift target against `zig-core/zig-out/lib/libtemperplayer.dylib`, so build the Zig library first. Use Zig **0.16.0** (not 0.14.x). Source builds resolve the dynamic library automatically; packaged apps should bundle it under `Contents/Frameworks`.

```bash
cd TemperPlayer  # from the repository root
swift test
swift run -c release
```

Tests use temporary databases and generated audio fixtures, not your music library. To manually try the UI with a separate empty library:

```bash
TEMPERPLAYER_LIBRARY_DIRECTORY="$(mktemp -d)" swift run -c release
```

A macOS CI workflow builds the native Zig core, runs the Swift tests, and validates release packaging. To build a native-architecture DMG locally:

```bash
./scripts/package-macos.sh /tmp/temperplayer-package
```

Use a fresh output directory. The script embeds the matching Zig dylib, removes source-only library paths, ad-hoc signs the bundle, and writes the DMG plus `SHA256SUMS`. Version metadata lives in `packaging/Info.plist`. The [release checklist](docs/release-checklist.md) covers signing/notarization and remaining manual validation gates.

## Architecture

```text
temper-player/
├── TemperPlayer/
│   ├── Package.swift
│   └── Sources/
│       ├── CTemperPlayer/   # C module and headers for the Zig boundary
│       └── TemperPlayer/
│           ├── App/         # Application and menu-bar lifecycle
│           ├── Audio/       # Playback graph, bridges, and realtime analysis
│           ├── Library/     # SQLite storage, import, metadata, and artwork
│           └── UI/          # Library, player, and visualization views
└── zig-core/
    └── src/
        ├── decoders/        # FLAC/WAV decoding for import and analysis
        ├── dsp/             # Pitch shifting and resampling
        └── c_abi.zig        # Stable boundary consumed by Swift
```

### Swift ↔ Zig boundary

The Swift package links a small C-facing dynamic library produced by Zig. Swift owns application state, persistence, the AVAudioEngine graph, and rendering. Zig owns the low-level routines where explicit sample-buffer control is useful: decoding, mastering measurements, and the pitch engine.

## Project status

v0.2.0 is the latest packaged release. See [CHANGELOG.md](CHANGELOG.md) for changes and [release notes](docs/releases/v0.2.0.md) for validation and limitations. This release does not claim a complete hardware/OS compatibility matrix or large-library performance certification.
