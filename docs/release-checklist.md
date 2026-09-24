# Release gates

A successful source build is not a signed, validated public release. The v0.2.0 package includes the library-management work but is only ad-hoc signed, not Developer ID signed or notarized. It is not universally production-ready based only on unit tests; the remaining gates below still apply.

## Automated validation

With Zig 0.16.0 and macOS 14+:

```sh
(cd zig-core && zig build -Dtarget=native --release=fast)
(cd TemperPlayer && swift test && swift build -c release)
```

Tests cover SQLite rollback/failed commits, playlist ordering, bulk removal without filesystem deletion, Unicode and large file sizes, history-preserving reimports, generated valid/corrupt/empty audio imports, cancellation, artwork persistence, search/selection, and queue/shuffle occurrence invariants. CI runs builds/tests and ad-hoc-signed packaging; it does not notarize or publish artifacts.

`./scripts/package-macos.sh /tmp/temperplayer-package` produces a native-architecture DMG and checksums in a fresh output directory. Official v0.2.0 downloads are Apple silicon. Check `packaging/Info.plist`, `zig-core/build.zig.zon`, README links, and release notes when changing versions.

## Manual acceptance

Use a throwaway library via `TEMPERPLAYER_LIBRARY_DIRECTORY`, generated/test audio, and a copy of an older database, never the sole copy of someone's library.

- Import individual files, mixed selections, recursive folders, symlinks, duplicates, corrupt audio, protected/inaccessible files, and an external drive. Cancel then retry. Verify counts and error messaging.
- Test actual FLAC, WAV, MP3, M4A, AAC, and MP4 audio; cover mono/stereo, 44.1/48/96 kHz, short/long files. Verify or explicitly reject unsupported channel layouts before advertising them.
- Bulk-remove tracks while paused/playing/shuffled; verify originals remain on disk and playlist/history/queue state stays consistent. Verify Cancel makes no changes.
- Create, rename, reorder, clear, and delete playlists. Check selection ranges and filtered lists. Verify metadata clears persist after restart and batch edits affect only checked fields.
- Disconnect/reconnect a drive; inspect missing entries before confirming cleanup. Test a read-only/unavailable library database.
- Run an extended playback session: pause/resume, end-of-queue replay, repeat modes, failed files, seeks near EOF, output-device changes, sleep/wake, menu-bar controls, and pitch changes.
- Check fresh-launch onboarding, compact and expanded window layouts, large UI scale, keyboard-only use, VoiceOver, and text editing without accidental transport/deletion shortcuts.
- Exercise a large library (10,000+ tracks), measuring startup, import responsiveness, memory, filtering, and playback UI cost. Artwork currently loads eagerly; this deserves profiling before large-library guarantees.
- Run on the minimum supported macOS and supported CPU architectures. One development Mac does not establish a compatibility matrix.

## Distribution (requires release owner credentials/approval)

- Package the executable, icon, Info.plist/version, and matching Zig dylib under `Contents/Frameworks`. Remove development-only absolute library search paths from shipped executables.
- Verify the bundle launches with the source checkout and developer tools unavailable.
- Sign nested dylibs and the app with the intended Developer ID, hardened runtime, and required entitlements; notarize and staple the app/DMG.
- Test Gatekeeper on a clean Mac/user account. Avoid making unsigned right-click/Open workarounds the normal installation experience.
- Review dependency licenses and bundle notices. Back up a real-world library before upgrade tests.
- Publish versioned release notes, system requirements, checksums, a support/bug-report route, and a rollback path only after approval.

## Explicit current limits

Local macOS app only. Library removal is not file trashing and has no Undo. Metadata edits do not write embedded tags. No automatic folder watching, file relinking, automatic library backups, cloud sync, or persistent play queue. These are product follow-ups, not features implied by the current UI.
