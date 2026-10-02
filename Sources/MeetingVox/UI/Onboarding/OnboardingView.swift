import SwiftUI

/// The window's content: rail | divider | step title, content, footer.
/// Presentational: every decision lives in `OnboardingModel`.
struct OnboardingView: View {
    let model: OnboardingModel
    let minutasStep: AnyView
    let listoStep: AnyView

    var body: some View {
        HStack(spacing: 0) {
            OnboardingRail(model: model)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                header
                ScrollView {
                    content
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer
            }
        }
        .frame(width: OnboardingWindowController.contentSize.width, height: OnboardingWindowController.contentSize.height)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.current.title).font(.title.weight(.semibold))
            Text(model.current.subtitle).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        switch model.current {
        case .permisos: PermissionsStepView(model: model)
        case .modelo: ModelStepView(model: model)
        case .minutas: minutasStep
        case .listo: listoStep
        }
    }

    private var footer: some View {
        HStack {
            if model.canGoBack {
                Button(Textos.Onboarding.atras) { model.back() }
            }
            Spacer()
            switch model.primary {
            case .continue:
                Button(Textos.Onboarding.continuar) { model.next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            case .start:
                Button(Textos.Onboarding.empezar) { model.finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}

/// Stands in for a step that ships later.
struct PlaceholderStepView: View {
    var body: some View {
        Text(Textos.Onboarding.pasoPendiente).foregroundStyle(.secondary)
    }
}
