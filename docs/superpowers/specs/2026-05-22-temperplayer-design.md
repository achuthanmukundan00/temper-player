# TemperPlayer — Blackbox Design

## Overview

Native macOS lossless audio player with a SwiftUI frontend and Zig audio decoding core. A DAW × terminal × debugger aesthetic — treats music as signals, buffers, and processes rather than streaming-library content.

**Name:** TemperPlayer
**Layout name:** Blackbox Layout
**UI language:** OLED console / temper deck / blackbox player

---

## Architecture

### Approach 2: Zig decoding library + Swift audio output

Zig compiles to a `.dylib` that decodes audio files to PCM. Swift uses AVAudioEngine to play the PCM buffers. Communication is through a thin C ABI surface.

```
┌──────────────────────────────────────────────────────┐
│  Swift (SwiftUI App)                                  │
│                                                        │
│  ┌────────────────────┐  ┌─────────────────────────┐  │
│  │ UI Layer           │  │ SQLite Library           │  │
│  │ • Blackbox layout  │  │ • tracks, playlists      │  │
│  │ • File tree panel  │  │ • play_history           │  │
│  │ • Inspector panel  │  │ • GRDB                   │  │
│  │ • Transport bar    │  └─────────────────────────┘  │
│  │ • Drag-drop import │                               │
│  └────────────────────┘                               │
│                                                        │
│  ┌──────────────────────────────────────────────────┐  │
│  │ AudioManager (Swift)                             │  │
│  │ • AVAudioEngine PCM output                       │  │
│  │ • Pulls PCM buffers from Zig decoder             │  │
│  │ • Manages playback state (play/pause/seek/next)  │  │
│  │ • Schedules buffers to AVAudioEngine source node  │  │
│  └──────────────┬───────────────────────────────────┘  │
│                 │ decode_read_frames() → PCM            │
└─────────────────┼──────────────────────────────────────┘
                  │
┌─────────────────┼──────────────────────────────────────┐
│  Zig Core (.dylib)                                     │
│                 │                                      │
│  decoders/ ────► ring_buffer ───► decode() → PCM      │
│  • dr_flac (FLAC)                                      │
│  • dr_wav (WAV)                                        │
│  • minimp3 (MP3)                                       │
│  • AAC via Apple AudioToolbox (bridged from Swift)     │
│                                                        │
│  Exposed C ABI:                                        │
│  decode_open(path) → decoder_handle                    │
│  decode_read_frames(handle, buf, count) → frames       │
│  decode_seek(handle, pcm_frame)                        │
│  decode_close(handle)                                  │
│  decode_get_info(handle) → SampleFormat                 │
│  metadata_read(path) → JSON string                     │
│  decode_get_mastering(path) → MasteringInfo (JSON)      │
└────────────────────────────────────────────────────────┘
```

### Audio Pipeline

1. `decode_open(path)` returns a handle to a decoder session
2. Swift calls `decode_read_frames(handle, &buf, 4096)` in a loop — each call fills the buffer with up to 4096 PCM frames
3. PCM is pulled into an AVAudioEngine source node's tap
4. `decode_seek(handle, frame_index)` for seeking
5. `decode_close(handle)` frees all decoder state

### Zig C ABI Surface

```c
// Opaque decoder handle
typedef void* decoder_handle;

// Audio format info
typedef struct {
    int sample_rate;
    int channels;
    int bit_depth;
    double duration_seconds;
} SampleFormat;

// Mastering metrics
typedef struct {
    double lufs;
    double true_peak_db;
    double peak_db;
    double dynamic_range_db;
    double phase_correlation;
    double dc_offset_pct;
    int    phase_ok;  // 0/1
} MasteringInfo;

decoder_handle decode_open(const char* path);
int decode_read_frames(decoder_handle h, float* buf, int frame_count);
int decode_seek(decoder_handle h, int64_t pcm_frame);
void decode_close(decoder_handle h);
SampleFormat decode_get_info(decoder_handle h);

// Metadata / mastering — these read and return immediately (no open needed)
char* metadata_read(const char* path);    // returns JSON string, caller frees
MasteringInfo decode_get_mastering(const char* path);
```

---

## Blackbox Layout (UI)

### Three-panel + transport deck

```
┌─λ─┬────────────── workspace / file tree / waveform ──────┬── inspector ─────┐
│ $ │ ~/Music/FESTER                                        │ BUFFER           │
│ ~ │ ├─ albums                                             │ /Users/achu/...  │
│ # │ ├─ drafts/                                            │                  │
│ ◎ │ │  └─ FESTER/                                        │ STREAM           │
│ λ │ │     ├─ 01-teeth.wav                                 │ format     flac  │
│   │ │     ├─ 02-buried.wav  ◄── playing                   │ sample_rate 96000│
│   │ │     └─ 03-demo.wav                                  │ bit_depth    24  │
│   │ └─ sets/                                              │ channels    2    │
│   │    └─ queue.tmp                                       │ ─────            │
│   │                                                        │ loudness -9.4   │
│   │  WAVEFORM                                              │ true_peak -0.8  │
│   │  ┌──────────────────────────────────┐                  │ peak     -1.2   │
│   │  │ ▂▃▅▇▁▂▆▇▃▁▁▅▇▂▃▆▁▂▇ │          │ dynamic 14.2    │
│   │  │ ▂▃▅▇▁▂▆▇▃▁▁▅▇▂▃▆▁▂▇ │          │ ─────            │
│   │  └──────────────────────────────────┘                  │ phase     ok    │
│   │  0:00   0:30   1:00   1:30   2:00   2:30               │ corr     +0.87  │
│   │                                                        │ dc_off  -0.001% │
├───┴─────────────── command / transport ────────────────────┴─────────────────┤
│ > playing ./FESTER/02-buried.wav   |◀ ◀ ▶ ▶▶|   01:23 / 04:56  vol:75 ▓▓▓░  │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Panel details

**Glyph spine (36px wide)** — vertical mode selector:
- `$` — file system mode (default, shown active)
- `~` — user library mode
- `#` — playlist/collection mode
- `◎` — metadata/batch-tag mode
- `λ` — processing/analysis mode (waveform, spectrogram)
- Bottom: `TERM` vertical label

**Workspace (center, flexible)** — file tree with highlighted playing track, large waveform as primary visual element with time ruler.

**Inspector (210px wide, right)** — mastering-grade signal monitor:
- BUFFER: full file path
- STREAM: format, sample rate, bit depth, channels, duration
- Divider
- Loudness (LUFS), true peak (dBTP), peak (dB), dynamic range
- Divider
- Phase (ok/warn/bad), correlation (+1.0 to -1.0), DC offset (%)
- Album art (20×20 thumbnail, fully optional)
- QUEUE: current + upcoming tracks

**Transport bar (34px tall, bottom):**
- Command prompt: `> playing ./path/to/file`
- Transport: `|◀ ◀ ▶ ▶▶|` (previous, rewind, play/pause, fast-forward, next)
- Timecode: `01:23 / 04:56`
- Volume: `vol:75` with tiny bar meter

### Visual language

- Pure black (`#000`) background — OLED friendly
- Monospace throughout — SF Mono / Menlo / Courier
- White (`#c5c5c5`) body text, dimmed (`#555`, `#333`) for metadata
- Green (`#6c6`) for positive signal metrics (phase ok, correlation)
- Amber (`#e6c34a`) for caution metrics (dc offset, near-zero values)
- 1px `#0f0f0f` borders for panel separation
- No rounded corners, no shadows, no gradients on UI chrome
- Waveform is the primary visual — album art is a tiny footnote

---

## Data Model (SQLite)

### Schema

```sql
-- Core: every imported audio file
CREATE TABLE tracks (
    id              TEXT PRIMARY KEY,     -- SHA-256 of canonical path
    path            TEXT NOT NULL,        -- absolute path on disk
    title           TEXT,
    artist          TEXT,
    album           TEXT,
    album_artist    TEXT,
    track_no        INTEGER,
    disc_no         INTEGER,
    year            INTEGER,
    genre           TEXT,
    duration        REAL,                 -- seconds
    format          TEXT,                 -- flac / wav / mp3 / m4a / aac
    sample_rate     INTEGER,
    bit_depth       INTEGER,
    channels        INTEGER,
    bitrate         INTEGER,
    file_size       INTEGER,
    date_added      TEXT NOT NULL,        -- ISO 8601
    last_played     TEXT,
    play_count      INTEGER DEFAULT 0,
    artwork_path    TEXT,                 -- path to extracted cover art (or NULL)
    dc_offset       REAL,
    lufs            REAL,
    true_peak       REAL,
    dynamic_range   REAL,
    phase_correlation REAL
);

-- Play history (for "recently played" and stats)
CREATE TABLE play_history (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    track_id  TEXT REFERENCES tracks(id) ON DELETE CASCADE,
    played_at TEXT NOT NULL               -- ISO 8601
);

-- Playlists (user-created and smart)
CREATE TABLE playlists (
    id          TEXT PRIMARY KEY,          -- UUID
    name        TEXT NOT NULL,
    description TEXT,
    is_smart    INTEGER DEFAULT 0,         -- 1 = smart playlist with rules
    smart_query TEXT,                      -- JSON query for smart playlists
    created     TEXT NOT NULL,             -- ISO 8601
    modified    TEXT NOT NULL              -- ISO 8601
);

-- Playlist membership
CREATE TABLE playlist_tracks (
    playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
    track_id    TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
    position    INTEGER NOT NULL,
    PRIMARY KEY (playlist_id, track_id)
);

-- Indexes
CREATE INDEX idx_tracks_artist ON tracks(artist);
CREATE INDEX idx_tracks_album ON tracks(album);
CREATE INDEX idx_tracks_genre ON tracks(genre);
CREATE INDEX idx_tracks_date_added ON tracks(date_added);
CREATE INDEX idx_play_history_played_at ON play_history(played_at);
CREATE INDEX idx_playlist_tracks_position ON playlist_tracks(playlist_id, position);
```

### Key design decisions

- **Track ID = SHA-256 of the absolute path** (Phase 1). Fast on import. Moving a file re-imports it — acceptable for Phase 1. Upgrade to content-addressable hashing in Phase 2.
- **Path is stored separately** from the ID, so the track record survives file moves (ID will be recomputed on re-import, old record archived).
- **Artwork extracted to file** at import time (e.g., `~/.temperplayer/art/<track_id>.jpg`)
- **Mastering metrics stored** per track so the inspector panel is a DB read, not a decode
- **Smart playlists** supported via `is_smart` + `smart_query` (JSON rules), deferred to Phase 2

---

## Drag-Drop Import Flow

1. User drags files/folders onto the app window (any panel)
2. SwiftUI `onDrop` handler receives the file URLs
3. For each URL:
   a. Check if extension is supported (flac, wav, mp3, m4a, aac, m4v)
   b. Compute track ID from file path (SHA-256 of the absolute path for Phase 1)
   c. Check if hash already exists in DB → skip if present
   d. Call Zig `metadata_read(path)` → parse JSON for title, artist, album, etc.
   e. Call Zig `decode_get_mastering(path)` → get LUFS, true peak, DC offset
   f. Extract artwork from `metadata_read` response (artwork returned as base64 in JSON) → decode and save to `~/.temperplayer/art/<track_id>.jpg`
   g. Copy file to organized library folder (optional, user preference)
   h. INSERT into `tracks` table
   i. Refresh file tree in workspace

### Supported formats

| Format | Decoder | Status |
|--------|---------|--------|
| FLAC   | dr_flac (C, via Zig) | Phase 1 |
| WAV    | dr_wav (C, via Zig) | Phase 1 |
| MP3    | minimp3 (C, via Zig) | Phase 2 |
| AAC    | Swift AVAssetReader (delegated) | Phase 2 |
| M4A    | Swift AVAssetReader (delegated) | Phase 2 |

*AAC/M4A require Apple's format-agnostic reader in Swift. MP3 uses minimp3 in Zig. All three are Phase 2 — Phase 1 ships FLAC + WAV.*

---

## Library Views (Phase 2)

Views accessible via glyph spine modes:
- `$` — file system tree (Phase 1, drag-drop focus)
- `~` — user library (Songs / Albums / Artists) (Phase 2)
- `#` — playlists (Phase 2)
- `◎` — metadata/tag editor (Phase 2)
- `λ` — analysis/processing (Phase 2)

Phase 1 ships with `$` mode active (file tree + drag-drop + playback). The remaining modes are added in Phase 2 along with full library browsing.

---

## Error Handling

### Import failures
- Unsupported format → log warning, skip file, continue batch
- Corrupt file → log error with path, continue
- Duplicate (hash exists) → skip silently
- Missing metadata → use file stem as title, blank for others

### Playback failures
- File removed between import and play → show "file not found" in transport bar, skip to next
- Decode error → log, skip to next track
- AVAudioEngine failure → show error overlay on transport bar, attempt restart

### UI errors
- DB read failure → show empty state, log error
- Artwork cache miss → show blank thumbnail (20×20 dark square)

---

## Phase 1 (this session) Build Order

1. **Zig core scaffold** — project structure, build.zig, C ABI exports, dr_flac + dr_wav integration
2. **Decoding** — decode_open/read/seek/close for FLAC + WAV, metadata_read, decode_get_mastering
3. **Swift project scaffold** — Xcode project, Zig dylib build phase, bridging header
4. **AudioManager** — AVAudioEngine + PCM scheduling, decode_read_frames loop, play/pause/seek
5. **SQLite library** — GRDB integration, schema migrations, import/query layer
6. **Blackbox UI** — glyph spine, file tree, waveform view, inspector panel, transport bar
7. **Drag-drop import** — onDrop handler, import pipeline, artwork extraction, refresh
8. **Playback wiring** — connect UI controls to AudioManager, track progression, now playing state
9. **Polish** — keyboard shortcuts (space = play/pause, arrows = seek/skip), window chrome removal
