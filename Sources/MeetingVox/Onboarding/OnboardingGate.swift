import Foundation

/// Whether the onboarding window opens at launch.
///
/// Pure on purpose: the caller gathers the facts (bundle, route, marker,
/// config presence) and this only decides, so every launch path is tested
/// without a bundle or a disk. `isBundled` is the caller's "this process can
/// use UserNotifications" predicate (`NotifierFactory.currentKind ==
/// .userNotifications`): the window touches the notification center, which
/// crashes without a bundle id, so one predicate serves both.
enum OnboardingGate {
    /// Bumped by a later change when new onboarding content should reach
    /// users who already completed an older one.
    static let currentVersion = 1

    /// Why the window shows, so it can greet a first run and an upgrading
    /// user (existing config, prefilled) differently.
    enum Reason: Equatable {
        case firstRun
        case upgrade
        case versionBump(from: Int)
    }

    enum Decision: Equatable {
        case show(Reason)
        case skip
    }

    /// Only the bundled app on its `run` route can show. A missing or
    /// unreadable marker shows again (closing without "Empezar" never writes
    /// one); a marker at or above `current` skips.
    static func decide(
        isBundled: Bool,
        isRunRoute: Bool,
        marker: OnboardingMarker.State,
        hasExistingConfig: Bool,
        current: Int = currentVersion
    ) -> Decision {
        guard isBundled, isRunRoute else { return .skip }
        switch marker {
        case .missing, .malformed:
            return .show(hasExistingConfig ? .upgrade : .firstRun)
        case .valid(let version):
            return version >= current ? .skip : .show(.versionBump(from: version))
        }
    }
}
