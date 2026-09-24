# TemperPlayer user guide

These features are included in v0.2.0. Requires macOS 14 or newer; the official download targets Apple silicon.

## Import and browse

- Choose **Import** or **File → Import Files or Folders…** (⌘O). Select multiple files/folders, or drop them into the main window.
- Folders are scanned recursively. Mono/stereo FLAC, WAV, MP3, M4A, AAC, and MP4 files containing readable audio are supported. Surround files must be converted to stereo before import. Corrupt, empty, video-only, and unsupported files are not added.
- One import runs at a time. **Cancel** stops the remaining work; successfully imported tracks stay in the library. The completion banner distinguishes imported, skipped, failed, and unprocessed files and includes the first failure reason.
- Importing an existing path again skips it, preserving your edits, playlists, and play counts. Overlapping folders and symlink paths are deduplicated. Different files with identical audio are not content-deduplicated.
- Files are referenced where they are, not copied. Keep removable drives connected and do not move files without expecting to reimport them.

The left navigation opens **Files**, **Artists & Albums**, **Playlists**, **Metadata**, and **Analyze**. Hover over an icon to see its name. Narrow windows use the compact player; widen the window to manage tracks. Library and playback commands remain in the macOS menu bar.

**Files** supports sort by recently added, title, artist, album/disc/track, duration, or recently played, with reverse order. Search matches words across titles, artists, albums, album artists, genres, formats, and paths, ignoring case and accents. Artist/album browsing also supports search and whole-album/artist actions.

Select tracks with a click, Command-click to toggle, or Shift-click for a range in Files and Playlists. Use the visible **Actions** menu or right-click for playback, queueing, playlist creation/membership, Finder reveal, or library removal.

## Removal and folder management

**Remove from Library…** removes the selected library entries, their playlist memberships, queue occurrences, and play history after confirmation. Removing the current track stops playback. **It never deletes or trashes your original audio files.** There is no Undo for library removal; reimporting restores tracks, but not their old memberships, library-only edits, or play counts.

Open the folder/gear button or **Library → Manage Library…**:

- See folders containing indexed tracks, reveal them in Finder, or **Scan for New Music**. This is a manual scan, not a background folder watcher. It adds new files and skips existing paths rather than refreshing edited metadata.
- **Remove Folder’s Tracks…** removes that displayed folder's indexed tracks after confirmation. Subfolders appear separately.
- Missing-file checks run off the UI thread. Reconnect external disks and check permissions before choosing **Remove Missing Entries…**; an unavailable drive must not be mistaken for permanently deleted music.

## Playlists

Create playlists with the sidebar **+**, **Library → New Playlist…**, or **Actions → Add to Playlist → New Playlist…**. The latter creates a playlist containing your selection. Existing memberships are not duplicated.

Playlist actions include play, queue, rename with explicit Save/Cancel, clear, and delete. Clear and delete require confirmation and never remove tracks from the main library. Use selected-track actions to remove playlist memberships or move a track up/down. Reordering is disabled while searching to avoid ambiguous positions.

## Metadata

Select tracks, then open **Metadata**. Edit title, artist, and album and choose **Save Changes**. For multiple tracks, check only the fields to change. An unchecked field is preserved; a checked empty field clears it.

Edits affect only the local library, **not the audio files' embedded tags**. Other file information is read-only. **Reset** discards the current form edits. Save before changing selection or leaving the Metadata view.

## Queue and playback

**Play** starts a track in its current list/album/playlist context. **Play Selection** uses only the selection. **Play Next** inserts immediately after the current song; **Add to Queue** appends.

The list button or **Library → Show Queue…** displays the entire queue, including previous/current/upcoming entries. Play an entry, move it up/down, or remove it. Removing the current entry stops it without automatically starting another song. **Clear Upcoming** retains only the current entry, if any. Queue edits do not modify playlists. The queue is session-only and is not restored after quitting.

Shuffle retains occurrence identity even if a song appears twice. Edits made during shuffle survive switching it off. Repeat cycles through Off, All, and One. Missing/unreadable tracks show an error and are skipped with a bounded search; an entirely unplayable queue stops instead of looping forever.

## Keyboard shortcuts

When not typing or interacting with a dialog:

| Shortcut | Action |
| --- | --- |
| ⌘O | Import files/folders |
| ⌘F | Focus search (opens Files if needed) |
| ⌘N | Create playlist |
| ⇧⌘M | Manage library |
| ⇧⌘J | Full queue |
| Space | Play/pause |
| Left / Right | Seek −5 / +5 seconds |
| ⌘Left / ⌘Right | Previous / next track |
| Up / Down | Select a visible track |
| Return | Play the selected visible track |
| Q | Add the selected visible track to queue |
| ⌘A | Select all visible tracks in Files/Artists & Albums; in Playlists use focused track list or its Select All action |
| Delete | Confirm library removal in Files/Artists & Albums; remove playlist membership when the playlist track list is focused |
| Escape | Cancel dialogs or clear/leave search |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / reset |

## Data and backups

By default the database and artwork live in `~/.temperplayer/`. Quit TemperPlayer before copying **the entire directory** for a backup (SQLite may also have journal files). Back up audio files separately; they are not stored inside the library directory. To restore, quit the app and replace its data directory with your backup, preserving a copy of the current directory first.

For development, `TEMPERPLAYER_LIBRARY_DIRECTORY=/absolute/path` selects an isolated database/artwork directory. UI preferences remain in macOS user defaults. There is no automatic backup, cloud sync, filesystem deletion, or file-relocation repair in this version.
