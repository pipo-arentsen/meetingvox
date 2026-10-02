import SwiftUI

/// The left rail: app name and the four numbered steps. A step's circle
/// shows its number, or a checkmark once it is done; the current one is
/// highlighted and every row is clickable (free navigation).
struct OnboardingRail: View {
    let model: OnboardingModel

    static let width: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Textos.Onboarding.nombreApp)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 20)
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                row(step)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 24)
        .frame(width: Self.width, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.4))
    }

    private func row(_ step: OnboardingStep) -> some View {
        let isCurrent = model.current == step
        let isDone = model.stepIsDone(step)
        return Button {
            model.jump(to: step)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isDone ? Color.green : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .frame(width: 24, height: 24)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text(verbatim: "\(step.number)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isCurrent ? Color.white : Color.primary)
                    }
                }
                Text(step.title)
                    .fontWeight(isCurrent ? .semibold : .regular)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .background(isCurrent ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
