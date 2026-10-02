import Foundation

/// The four onboarding steps, in rail order.
enum OnboardingStep: Int, CaseIterable, Equatable {
    case permisos = 1
    case modelo
    case minutas
    case listo
}

/// Navigation state of the onboarding window: which step is open and which
/// were opened. Free navigation (rail, "Atrás", "Continuar"); no step's state
/// ever blocks moving on, so `next()` takes no facts and `StepFacts` only
/// feeds `isDone`, a purely informational checkmark.
struct OnboardingFlow: Equatable {
    /// What the primary footer button says: "Continuar" on steps 1–3,
    /// "Empezar" on the last.
    enum Primary: Equatable {
        case `continue`
        case start
    }

    /// The facts that decide each step's checkmark. The model derives them
    /// (a `notApplicable` row counts as done); this type only reads them.
    struct StepFacts: Equatable {
        var permissionsDone: Bool
        var modelDone: Bool
        var minutesDone: Bool
    }

    private(set) var current: OnboardingStep = .permisos
    private(set) var visited: Set<OnboardingStep> = [.permisos]

    var canGoBack: Bool { current != OnboardingStep.allCases.first }

    var primary: Primary { current == OnboardingStep.allCases.last ? .start : .continue }

    mutating func next() {
        guard let step = OnboardingStep(rawValue: current.rawValue + 1) else { return }
        jump(to: step)
    }

    mutating func back() {
        guard let step = OnboardingStep(rawValue: current.rawValue - 1) else { return }
        jump(to: step)
    }

    mutating func jump(to step: OnboardingStep) {
        current = step
        visited.insert(step)
    }

    /// "Listo" is never done: it is the destination, not a task.
    static func isDone(_ step: OnboardingStep, facts: StepFacts) -> Bool {
        switch step {
        case .permisos: facts.permissionsDone
        case .modelo: facts.modelDone
        case .minutas: facts.minutesDone
        case .listo: false
        }
    }
}
