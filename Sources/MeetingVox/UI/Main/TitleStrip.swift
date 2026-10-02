import SwiftUI

/// The window's top strip (the title bar is transparent and lets content run
/// under it): the app name and the red record button. Room is left at the
/// leading edge for the window's traffic lights.
struct TitleStrip: View {
    let state: RecordButtonState
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                if let feather = AppGlyph.feather(side: 15) {
                    Image(nsImage: feather)
                }
                Text(AppIdentity.displayName)
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.leading, MainLayout.trafficLightsInset)
            Spacer()
            Button(action: onToggle) {
                HStack(spacing: 6) {
                    Image(systemName: state.isRecording ? "stop.fill" : "circle.fill")
                        .font(.system(size: state.isRecording ? 9 : 8))
                    Text(state.title)
                        .monospacedDigit()
                    if !state.isRecording {
                        Text(Textos.Principal.atajoGrabar).opacity(0.8)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(MainPalette.recording))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .frame(height: MainLayout.titleStripHeight)
        .background(MainPalette.chrome)
    }
}
