import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject var library: Database
    @EnvironmentObject var playerState: PlayerState
    @Binding var hoveredTrackId: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("~/Music")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.4))
                Spacer()
                Text("\(library.tracks.count) files")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(Color(white: 0.25))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.black)

            FileTreeView(hoveredTrackId: $hoveredTrackId)
                .frame(maxHeight: .infinity)

            if playerState.currentTrack != nil {
                WaveformView()
                    .frame(height: 100)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
        }
        .background(Color.black)
        .overlay(
            Rectangle().fill(Color(white: 0.06)).frame(width: 1).frame(maxWidth: .infinity, alignment: .trailing)
        )
    }
}
