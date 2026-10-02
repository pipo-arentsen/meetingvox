import Testing

@testable import MeetingVox

/// The four-step state machine behind the rail, "Atrás" and "Continuar".
/// "Done" is informational: it never gates navigation.
@Suite("OnboardingFlow")
struct OnboardingFlowTests {
    @Test func stepsAreFourNumberedInOrder() {
        #expect(OnboardingStep.allCases == [.permisos, .modelo, .minutas, .listo])
        #expect(OnboardingStep.allCases.map(\.rawValue) == [1, 2, 3, 4])
    }

    @Test func startsOnPermisosWithNoWayBack() {
        let flow = OnboardingFlow()
        #expect(flow.current == .permisos)
        #expect(!flow.canGoBack)
        #expect(flow.visited == [.permisos])
    }

    @Test func nextWalksForwardAndStopsOnTheLastStep() {
        var flow = OnboardingFlow()
        flow.next()
        #expect(flow.current == .modelo)
        flow.next()
        #expect(flow.current == .minutas)
        flow.next()
        #expect(flow.current == .listo)
        flow.next()
        #expect(flow.current == .listo)
    }

    @Test func backWalksBackwardAndStopsOnTheFirstStep() {
        var flow = OnboardingFlow()
        flow.jump(to: .minutas)
        flow.back()
        #expect(flow.current == .modelo)
        #expect(flow.canGoBack)
        flow.back()
        #expect(flow.current == .permisos)
        #expect(!flow.canGoBack)
        flow.back()
        #expect(flow.current == .permisos)
    }

    @Test func jumpOpensAnyStepFromAnyStep() {
        var flow = OnboardingFlow()
        flow.jump(to: .listo)
        #expect(flow.current == .listo)
        flow.jump(to: .modelo)
        #expect(flow.current == .modelo)
        flow.jump(to: .permisos)
        #expect(flow.current == .permisos)
    }

    @Test func visitedRemembersEveryStepOpened() {
        var flow = OnboardingFlow()
        flow.jump(to: .minutas)
        flow.back()
        #expect(flow.visited == [.permisos, .modelo, .minutas])
        flow.next()
        flow.next()
        #expect(flow.visited == Set(OnboardingStep.allCases))
    }

    @Test func primaryIsContinueOnEveryStepButTheLastWhereItIsStart() {
        var flow = OnboardingFlow()
        for step in [OnboardingStep.permisos, .modelo, .minutas] {
            flow.jump(to: step)
            #expect(flow.primary == .continue, "step \(step)")
        }
        flow.jump(to: .listo)
        #expect(flow.primary == .start)
    }

    @Test func continueIsNeverBlockedByAnUndoneStep() {
        // Nothing done at all: facts are informational, `next` takes none.
        let nothing = OnboardingFlow.StepFacts(permissionsDone: false, modelDone: false, minutesDone: false)
        var flow = OnboardingFlow()
        #expect(!OnboardingFlow.isDone(.permisos, facts: nothing))
        flow.next()
        #expect(flow.current == .modelo)
        #expect(!OnboardingFlow.isDone(.modelo, facts: nothing))
        flow.next()
        #expect(flow.current == .minutas)
    }

    @Test func isDoneFollowsEachStepsOwnFact() {
        let only = { (p: Bool, m: Bool, n: Bool) in
            OnboardingFlow.StepFacts(permissionsDone: p, modelDone: m, minutesDone: n)
        }
        #expect(OnboardingFlow.isDone(.permisos, facts: only(true, false, false)))
        #expect(!OnboardingFlow.isDone(.permisos, facts: only(false, true, true)))
        #expect(OnboardingFlow.isDone(.modelo, facts: only(false, true, false)))
        #expect(!OnboardingFlow.isDone(.modelo, facts: only(true, false, true)))
        #expect(OnboardingFlow.isDone(.minutas, facts: only(false, false, true)))
        #expect(!OnboardingFlow.isDone(.minutas, facts: only(true, true, false)))
    }

    @Test func theListoStepIsNeverDone() {
        let everything = OnboardingFlow.StepFacts(permissionsDone: true, modelDone: true, minutesDone: true)
        #expect(!OnboardingFlow.isDone(.listo, facts: everything))
    }
}
