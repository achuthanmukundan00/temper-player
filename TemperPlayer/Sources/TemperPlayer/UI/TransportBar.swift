import SwiftUI

struct TransportBar: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var playerState: PlayerState
    @EnvironmentObject var playback: PlaybackController
    @Environment(\.uiScale) var uiScale

    var body: some View {
        HStack(spacing: 10 * uiScale) {
            Text(playerState.displayPath)
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            HStack(spacing: 4 * uiScale) {
                shuffleButton
                repeatButton
                PitchKnobView(value: $playerState.pitchShift, range: -1200...1200, onChange: { playback.setPitchShift($0) })
                    .frame(width: 16 * uiScale, height: 16 * uiScale)
                transportButton(systemName: "backward.fill") { playback.previous() }
                transportButton(systemName: "gobackward.5") { playback.seek(by: -5) }
                playPauseButton
                transportButton(systemName: "goforward.5") { playback.seek(by: 5) }
                transportButton(systemName: "forward.fill") { playback.next() }
            }

            Text("\(playerState.timeString) / \(playerState.durationString)")
                .font(.system(size: 9 * uiScale))
                .foregroundStyle(.secondary)

            HStack(spacing: 4 * uiScale) {
                Image(systemName: "speaker.wave.1.fill")
                    .font(.system(size: 8 * uiScale))
                    .foregroundStyle(.tertiary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(.secondary)
                            .frame(width: geo.size.width * CGFloat(playerState.volume))
                    }
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        let vol = Float(min(1, max(0, v.location.x / geo.size.width)))
                        playback.setVolume(vol)
                    })
                }
                .frame(width: 32 * uiScale, height: 4 * uiScale)
            }
        }
        .padding(.horizontal, 14 * uiScale)
        .frame(height: 34 * uiScale)
        .background(Color.black)
        .overlay(
            Rectangle()
                .fill(.quaternary.opacity(0.5))
                .frame(height: 0.5)
                .frame(maxHeight: .infinity, alignment: .top)
        )
    }

    private func transportButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 8 * uiScale, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var playPauseButton: some View {
        Button(action: { playback.togglePlayPause() }) {
            Image(systemName: playerState.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 9 * uiScale, weight: .medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 22, minHeight: 22)
                .overlay(Circle().stroke(.tertiary, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var shuffleColor: Color {
        playerState.isShuffled ? Color(red: 0.3, green: 0.8, blue: 0.4) : Color(white: 0.35)
    }

    private var shuffleButton: some View {
        Button(action: { playback.toggleShuffle() }) {
            Image(systemName: "shuffle")
                .font(.system(size: 8 * uiScale, weight: .medium))
                .foregroundStyle(shuffleColor)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var repeatButton: some View {
        Button(action: { playback.cycleRepeatMode() }) {
            Image(systemName: repeatIconName)
                .font(.system(size: 8 * uiScale, weight: .medium))
                .foregroundStyle(repeatColor)
                .frame(minWidth: 22, minHeight: 22)
                .contentShape(Rectangle())
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
        case .off: return Color(white: 0.35)
        case .all, .one: return Color(red: 0.3, green: 0.8, blue: 0.4)
        }
    }
}

private struct PitchKnobView: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let onChange: (Float) -> Void
    @State private var isDragging = false
    @State private var dragStartValue: Float = 0
    @State private var lastTapTime: Date = .distantPast
    @Environment(\.uiScale) var uiScale

    private var rotation: Angle {
        .degrees(Double((value - range.lowerBound) / (range.upperBound - range.lowerBound) * 270 - 135))
    }

    var body: some View {
        Circle()
            .stroke(isDragging ? Color.white : Color(white: 0.35), lineWidth: 1.5)
            .overlay(
                Rectangle()
                    .fill(isDragging ? Color.white : Color(white: 0.35))
                    .frame(width: 1.5, height: 4)
                    .offset(y: -7)
                    .rotationEffect(rotation)
            )
            .frame(minWidth: 24, minHeight: 24)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                        }
                        let delta = Float(-v.translation.height) / 100
                        let range_float = range.upperBound - range.lowerBound
                        let newValue = max(range.lowerBound, min(range.upperBound, dragStartValue + delta * range_float))
                        value = newValue
                        onChange(newValue)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
            .onTapGesture(count: 2) {
                value = 0
                onChange(0)
            }
    }
}
