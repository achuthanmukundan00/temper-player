import SwiftUI

struct QueueView: View {
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Play Queue").font(.title2.bold())
                    Text("\(playerState.queue.count) tracks · \(playerState.queueTitle)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if playerState.queue.isEmpty {
                ContentUnavailableView("Your queue is empty", systemImage: "text.line.first.and.arrowtriangle.forward",
                                       description: Text("Choose Play Next or Add to Queue on any track, album, or playlist."))
            } else {
                List {
                    ForEach(Array(playerState.queue.enumerated()), id: \.offset) { index, track in
                        queueRow(track, at: index)
                    }
                }
                .listStyle(.inset)
            }
            HStack {
                Button(playerState.isShuffled ? "Shuffle: On" : "Shuffle: Off") { playback.toggleShuffle() }
                Button("Repeat: \(repeatTitle)") { playback.cycleRepeatMode() }
                Spacer()
                Button("Clear Upcoming") { playback.clearUpcomingQueue() }
                    .disabled(playerState.upcomingQueue.isEmpty)
            }
            Text("Queue changes do not change your playlists or library.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 650, minHeight: 380, idealHeight: 520)
    }

    private var repeatTitle: String {
        switch playerState.repeatMode {
        case .off: return "Off"
        case .all: return "All"
        case .one: return "One"
        }
    }

    private func queueRow(_ track: Track, at index: Int) -> some View {
        HStack(spacing: 12) {
            Button { playback.playQueueItem(at: index) } label: {
                Image(systemName: playerState.queueIndex == index ? "speaker.wave.2.fill" : "play.fill")
            }
            .buttonStyle(.plain).help("Play \(track.displayTitle)")
            .accessibilityLabel("Play \(track.displayTitle)")
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle).lineLimit(1)
                Text(track.artist ?? "Unknown Artist").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(track.formattedDuration).monospacedDigit().foregroundStyle(.secondary)
            Button { playback.moveQueueItem(from: index, to: index - 1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0).help("Move up").accessibilityLabel("Move up")
            Button { playback.moveQueueItem(from: index, to: index + 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index + 1 == playerState.queue.count).help("Move down").accessibilityLabel("Move down")
            Button { playback.removeQueueItem(at: index) } label: { Image(systemName: "xmark") }
                .help("Remove from queue").accessibilityLabel("Remove \(track.displayTitle) from queue")
        }
        .padding(.vertical, 5)
    }
}
