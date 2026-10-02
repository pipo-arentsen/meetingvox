import SwiftUI

/// A list row's one status chip: a small capsule in the tone of its
/// pill, with a spinner while something is actually being worked on.
struct StatusPillView: View {
    let pill: StatusPill
    /// In a list row the pill yields width to the meta text (the app name must
    /// not be cut) and truncates its own label instead; elsewhere it keeps its
    /// natural width.
    var truncates = false

    var body: some View {
        HStack(spacing: 5) {
            if pill.isBusy {
                SpinnerView()
            } else if pill.tone == .recording {
                Circle().frame(width: 6, height: 6)
            }
            Text(pill.label)
                .truncationMode(.tail)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .fixedSize(horizontal: !truncates, vertical: true)
        .padding(.horizontal, 7)
        .padding(.vertical, 1)
        .foregroundStyle(foreground)
        .background(Capsule().fill(background))
    }

    private var foreground: Color {
        switch pill.tone {
        case .recording: .white
        case .error: MainPalette.error
        case .running: MainPalette.accent
        case .neutral: MainPalette.muted
        }
    }

    private var background: Color {
        switch pill.tone {
        case .recording: MainPalette.recording
        case .error: MainPalette.errorBackground
        case .running: MainPalette.accentBackground
        case .neutral: MainPalette.sunken
        }
    }
}

/// A ring that turns; still under "Reducir movimiento". 9 pt in a pill,
/// larger in the stepper.
struct SpinnerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false
    var diameter: CGFloat = 9

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            .frame(width: diameter, height: diameter)
            .rotationEffect(.degrees(turning ? 360 : 0))
            .accessibilityLabel(Textos.Principal.enCurso)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { turning = true }
            }
    }
}
