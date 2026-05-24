
<div>
  <h1 align="center">temperplayer</h1>
<p align="center">
<img width="1280" height="720" alt="temperplayer" src="https://github.com/user-attachments/assets/21460c7f-2bb7-4c37-8a1f-e367e1821284" />

</p>
</div>
<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/language-Swift%205.9-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/engine-Zig%20audio%20core-yellow?logo=zig" alt="Zig">
  <img src="https://img.shields.io/badge/version-0.0.1-blueviolet" alt="Version">
  <img src="https://img.shields.io/badge/license-MIT-brightgreen" alt="License">
</p>

A fast, native audiophile music player for macOS. Built with SwiftUI and a custom Zig audio engine for minimal latency and maximum format support.

## Features

- **Wide Format Support** — FLAC, WAV, AIFF, MP3, AAC, OGG, and more, powered by the temperplayer Zig decoder library
- **Menu Bar Mini Player** — Quick playback controls right from the menu bar with a native Control Center-style popover
- **Responsive Layout** — Window seamlessly adapts from a super-compact player (320px) to a full workspace with visualizers (800px+)
- **Library Management** — Import folders, browse by filesystem tree, and manage playlists
- **Realtime Visualizers** — Spectrogram, waveform, and multiband frequency analysis
- **Play Queue** — Enqueue tracks, reorder on‑the‑fly, skip, and clear upcoming
- **Gapless Playback** — Smooth transitions between consecutive tracks
- **Artwork Display** — Embedded album art from your music files
- **Keyboard Shortcuts** — Full transport control without touching the mouse

## Installation

### Download

Grab the latest DMG from the [Releases](https://github.com/achuthanmukundan00/temper-player/releases) page.

### Build from Source

```bash
# Clone the repo
git clone https://github.com/achuthanmukundan00/temper-player.git
cd temper-player

# Build the Zig audio core
cd zig-core
zig build -Doptimize=ReleaseFast

# Build the Swift app
cd ../TemperPlayer
swift build -c release
```

> **Prerequisites:** Xcode 15+, Swift 5.9+, Zig 0.13+

## Usage

### Menu Bar

TemperPlayer lives in your menu bar. Click the ▶ icon to open the mini player with art, track info, and full transport controls.

### Import Music

- **File → Import Folder...** (`⌘O`) — point TemperPlayer at your music directory
- **Drag & Drop** — drop files or folders onto the main window

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `Space` | Play / Pause |
| `←` | Seek backward 5s |
| `→` | Seek forward 5s |
| `↑` / `↓` | Navigate track list |
| `Enter` | Play selected track |
| `Q` | Enqueue selected track |
| `⌘=` / `⌘-` | Zoom in/out |
| `⌘0` | Reset zoom |

## Architecture

```
temper-player/
├── TemperPlayer/          # SwiftUI macOS app
│   ├── Sources/
│   │   ├── App/           # App entry point + menu bar controller
│   │   ├── Audio/         # Audio manager, playback controller, analyzer
│   │   ├── Library/       # Database, models, import service
│   │   ├── UI/            # All SwiftUI views
│   │   ├── Extensions/    # Environment keys, crypto helpers
│   │   └── CTemperPlayer/ # C bridge to Zig library
│   └── Package.swift
└── zig-core/              # Zig audio decoder library
    └── src/               # Low-level format decoders (FLAC, WAV, MP3, etc.)
```

## License

MIT © 2025 TemperPlayer
