import Testing

@testable import MeetingVox

/// The gate decides, from facts the caller already gathered, whether the
/// onboarding window opens at launch. It is pure: no disk, no bundle lookup.
@Suite("OnboardingGate")
struct OnboardingGateTests {
    private func decide(
        bundled: Bool = true,
        run: Bool = true,
        marker: OnboardingMarker.State,
        existingConfig: Bool = false,
        current: Int = 1
    ) -> OnboardingGate.Decision {
        OnboardingGate.decide(
            isBundled: bundled, isRunRoute: run, marker: marker,
            hasExistingConfig: existingConfig, current: current
        )
    }

    @Test func currentVersionIsOne() {
        #expect(OnboardingGate.currentVersion == 1)
    }

    // MARK: Never outside the bundled `run`

    @Test func theBareBinaryNeverShowsEvenWithoutAMarker() {
        #expect(decide(bundled: false, marker: .missing) == .skip)
        #expect(decide(bundled: false, marker: .malformed) == .skip)
    }

    @Test func aCLISubcommandNeverShows() {
        #expect(decide(run: false, marker: .missing) == .skip)
        #expect(decide(bundled: false, run: false, marker: .valid(version: 0)) == .skip)
    }

    // MARK: Marker states

    @Test func noMarkerOnAFreshMachineIsAFirstRun() {
        #expect(decide(marker: .missing) == .show(.firstRun))
    }

    @Test func noMarkerWithAnExistingConfigIsAnUpgrade() {
        #expect(decide(marker: .missing, existingConfig: true) == .show(.upgrade))
    }

    @Test func aMalformedMarkerShowsAgainWithTheSameReasonsAsMissing() {
        #expect(decide(marker: .malformed) == .show(.firstRun))
        #expect(decide(marker: .malformed, existingConfig: true) == .show(.upgrade))
    }

    @Test func anOlderMarkerIsAVersionBumpThatRemembersTheOldVersion() {
        #expect(decide(marker: .valid(version: 0), current: 2) == .show(.versionBump(from: 0)))
        #expect(decide(marker: .valid(version: 1), current: 3) == .show(.versionBump(from: 1)))
    }

    @Test func aVersionBumpIgnoresWhetherAConfigExists() {
        #expect(decide(marker: .valid(version: 1), existingConfig: true, current: 2)
            == .show(.versionBump(from: 1)))
        #expect(decide(marker: .valid(version: 1), existingConfig: false, current: 2)
            == .show(.versionBump(from: 1)))
    }

    @Test func aMarkerAtTheCurrentVersionSkips() {
        #expect(decide(marker: .valid(version: 1), current: 1) == .skip)
        #expect(decide(marker: .valid(version: 1), existingConfig: true) == .skip)
    }

    @Test func aNewerMarkerSkipsSoADowngradedBuildDoesNotNagAgain() {
        #expect(decide(marker: .valid(version: 5), current: 2) == .skip)
    }

    @Test func defaultsToTheCurrentVersion() {
        let atCurrent = OnboardingGate.decide(
            isBundled: true, isRunRoute: true,
            marker: .valid(version: OnboardingGate.currentVersion), hasExistingConfig: false
        )
        #expect(atCurrent == .skip)
        let below = OnboardingGate.decide(
            isBundled: true, isRunRoute: true,
            marker: .valid(version: OnboardingGate.currentVersion - 1), hasExistingConfig: false
        )
        #expect(below == .show(.versionBump(from: OnboardingGate.currentVersion - 1)))
    }
}
