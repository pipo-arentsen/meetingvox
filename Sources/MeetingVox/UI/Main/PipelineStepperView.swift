import SwiftUI

/// Grabada, Transcrita, Minuta, Resumen, Memoria (PS-1..3): a green check for
/// done, a spinner for active, a red ! for failed (with "Reintentar"), a
/// dashed ring for pending and a gray dash for a step that will not happen.
/// It draws `PipelineStepper.derive`'s result and decides nothing.
struct PipelineStepperView: View {
    let steps: [PipelineStep]
    let onRetry: (PipelineStep.Kind) -> Void
    /// Set when Memoria may be sent from here ("Enviar"); nil hides the link.
    var onSend: (() -> Void)?
    /// What memory says about the session ("En memoria (banco) — fecha"…),
    /// muted at the trailing edge; nil = nothing to say.
    var memoryLine: String?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                StepView(
                    step: step, onRetry: { onRetry(step.kind) },
                    onSend: step.kind == .memoria && step.state == .pending ? onSend : nil
                )
                if index < steps.count - 1 {
                    Rectangle()
                        .fill(step.state == .done ? MainPalette.ok : MainPalette.line)
                        .frame(width: 34, height: 1.5)
                        .padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 12)
            if let memoryLine {
                Text(memoryLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(MainPalette.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
}

private struct StepView: View {
    let step: PipelineStep
    let onRetry: () -> Void
    let onSend: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            StepMarker(state: step.state)
            Text(step.title)
                .font(.system(size: 11.5))
                .foregroundStyle(titleColor)
            if step.state == .failed {
                link(Textos.Principal.reintentarPaso, action: onRetry)
            } else if let onSend {
                link(Textos.Principal.enviarPaso, action: onSend)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Textos.Principal.estadoPaso(step.title, stateWord))
    }

    private func link(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11.5))
            .foregroundStyle(MainPalette.accent)
    }

    private var titleColor: Color {
        switch step.state {
        case .done, .active: .primary
        case .failed: MainPalette.error
        case .pending, .skipped: MainPalette.muted
        }
    }

    private var stateWord: String {
        switch step.state {
        case .done: Textos.Principal.estadoHecho
        case .active: Textos.Principal.estadoEnCurso
        case .pending: Textos.Principal.estadoPendiente
        case .failed: Textos.Principal.estadoError
        case .skipped: Textos.Principal.estadoOmitido
        }
    }
}

/// The 16 pt circle of one step.
private struct StepMarker: View {
    let state: PipelineStep.State
    private let size: CGFloat = 16

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(MainPalette.ok)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy)).foregroundStyle(.white)
            case .active:
                Circle().stroke(MainPalette.line, lineWidth: 1.5)
                SpinnerView(diameter: 11).foregroundStyle(MainPalette.accent)
            case .failed:
                Circle().fill(MainPalette.error)
                Text("!").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
            case .pending:
                Circle().stroke(MainPalette.line, style: StrokeStyle(lineWidth: 1.5, dash: [2.5, 2]))
            case .skipped:
                Circle().stroke(MainPalette.line, lineWidth: 1.5)
                Text("–").font(.system(size: 10, weight: .semibold)).foregroundStyle(MainPalette.muted)
            }
        }
        .frame(width: size, height: size)
    }
}
