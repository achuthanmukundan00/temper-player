import SwiftUI

enum Mode: String, CaseIterable {
    case files = "$"
    case library = "~"
    case playlists = "#"
    case tag = "\u{25CE}"
    case analyze = "\u{03BB}"

    var label: String { rawValue }
}

struct GlyphSpine: View {
    @Binding var activeMode: Mode
    @State private var hoveredMode: Mode?

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Mode.allCases, id: \.self) { mode in
                Text(mode.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(foreground(for: mode))
                    .frame(width: 36, height: 24)
                    .background(background(for: mode))
                    .onHover { hovering in
                        hoveredMode = hovering ? mode : nil
                    }
                    .onTapGesture { activeMode = mode }
            }

            Spacer()

            Text("TERM")
                .font(.system(size: 7, design: .monospaced))
                .foregroundColor(Color(white: 0.15))
                .rotationEffect(.degrees(-90))
                .fixedSize()
        }
        .padding(.vertical, 12)
        .frame(width: 36)
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
        )
    }

    private func foreground(for mode: Mode) -> Color {
        if mode == activeMode { return .white }
        if mode == hoveredMode { return Color(white: 0.6) }
        return Color(white: 0.2)
    }

    private func background(for mode: Mode) -> some View {
        Group { if mode == activeMode { Color.white.opacity(0.05) } else { Color.clear } }
    }
}
