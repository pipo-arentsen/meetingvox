import Foundation

/// Pure decision logic for "the meeting ended — stop recording?", run only
/// while quill records. Same inputs as `MeetingDetectionMachine` (matched
/// processes with input running at `now`, injected clock), so tests drive it
/// without Core Audio.
///
/// A meeting app is *watched* once it has captured input continuously for
/// its own threshold (3 s; WhatsApp 8 s) during this recording, so a voice
/// note or a browser mic probe never counts. An app already in a call when
/// the recording starts counts once it keeps capturing that long. When every
/// watched app has stopped capturing for a continuous `grace` after a
/// release, the machine asks once. Any watched app capturing again inside
/// the grace cancels the pending prompt.
///
/// After a prompt the machine is *disarmed*: it asks again only after a new
/// qualifying capture (continuous for the threshold) followed by another
/// release — "Seguir grabando" means "not for this silence", and a capture
/// that qualified while the panel was up still counts. A qualifying capture,
/// or the named app becoming ignored, *withdraws* the outstanding prompt
/// (`outstanding` goes nil) so the driver closes its panel. It never stops
/// anything itself; only a click stops the recording.
struct MeetingEndMachine {
    /// Continuous all-idle time before asking. Teams releases the input
    /// within a second of hanging up; the grace absorbs short releases
    /// (device switches, and possibly muting — unverified per app).
    static let grace: TimeInterval = 15

    struct Context: Sendable {
        var now: Date
        /// `meeting_detection.enabled` and `prompt_on_end` (off → never asks
        /// and forgets what it watched).
        var enabled = true
        /// Rule ids or bundle ids from `meeting_detection.ignored_apps`.
        var ignored: Set<String> = []
        /// The end panel is on screen: hold (don't consume) another prompt.
        var promptVisible = false
        var ownPID: pid_t = getpid()
    }

    struct Prompt: Sendable, Equatable {
        /// The watched app that released the input last (the panel names it).
        let app: MeetingApp
    }

    /// For `quill diag --mode processes --simulate-recording`.
    enum Status: Sendable, Equatable {
        case disabled
        /// No meeting app has captured input for its threshold during this
        /// recording.
        case notWatching
        /// Watched apps still capturing (rule ids, sorted).
        case capturing([String])
        /// Every watched app idle; asks at `elapsed == grace`.
        case grace(elapsed: TimeInterval, grace: TimeInterval)
        /// Idle, but already asked (or answered) for this silence: waits for
        /// a new capture.
        case disarmed
    }

    private struct Tracked {
        let app: MeetingApp
        /// Start of the current capture run (nil = idle).
        var capturingSince: Date?
        /// Last step that saw the current run capturing.
        var lastSeen: Date?
        /// The current run already reached the threshold.
        var runQualified = false
        /// Some run reached the threshold during this recording.
        var watched = false
    }

    private var apps: [String: Tracked] = [:]
    /// A qualifying capture happened since the last prompt: the flag that
    /// lets the next release ask again ("captured since prompt").
    private var armed = false
    /// Since when every watched app is idle (nil while any captures, or when
    /// the all-idle state came from an ignore change rather than a release).
    private var idleSince: Date?
    private var lastReleased: MeetingApp?
    /// The prompt on screen, until answered (`dismissed`) or withdrawn.
    private(set) var outstanding: Prompt?

    /// Advance to `context.now`. Returns at most one prompt per step.
    mutating func step(_ observations: [MeetingDetectionMachine.Observation], _ context: Context) -> Prompt? {
        guard context.enabled else {
            self = MeetingEndMachine()
            return nil
        }
        let now = context.now
        var active: [String: MeetingApp] = [:]
        for observation in observations
        where observation.pid != context.ownPID && !observation.app.isIgnored(by: context.ignored) {
            active[observation.app.id] = observation.app
        }
        // An app ignored mid-recording stops counting right away, and is
        // never named.
        apps = apps.filter { !$0.value.app.isIgnored(by: context.ignored) }
        if let last = lastReleased, last.isIgnored(by: context.ignored) { lastReleased = nil }
        if let prompt = outstanding, prompt.app.isIgnored(by: context.ignored) { outstanding = nil }

        // Qualify runs first, so a run ending in this step counts — but only
        // up to the last step that saw it capturing: Core Audio does not
        // notify a release (`IsRunningInput`), so one seen late by a rescan
        // must not turn a brief probe into a qualifying capture.
        qualify(at: now, active: Set(active.keys))
        var released = false
        for id in apps.keys.sorted() where active[id] == nil && apps[id]?.capturingSince != nil {
            apps[id]?.capturingSince = nil
            apps[id]?.runQualified = false
            if apps[id]?.watched == true {
                released = true
                lastReleased = apps[id]?.app // sorted: deterministic when several release at once
            }
        }
        for id in active.keys.sorted() {
            var tracked = apps[id] ?? Tracked(app: active[id]!)
            if tracked.capturingSince == nil { tracked.capturingSince = now }
            tracked.lastSeen = now
            apps[id] = tracked
        }

        let watched = apps.values.filter(\.watched)
        guard !watched.isEmpty, !watched.contains(where: { $0.capturingSince != nil }) else {
            idleSince = nil
            return nil
        }
        // Only a release starts the grace (not an ignore change).
        if idleSince == nil, released { idleSince = now }
        guard armed, !context.promptVisible, let since = idleSince, now.timeIntervalSince(since) >= Self.grace,
              let app = lastReleased ?? watched.map(\.app).sorted(by: { $0.id < $1.id }).first
        else { return nil }
        armed = false
        outstanding = Prompt(app: app)
        return outstanding
    }

    /// The panel was answered ("Seguir grabando") or closed. Only a
    /// qualifying capture since the prompt (even one while the panel was up)
    /// lets the next release ask again.
    mutating func dismissed() {
        outstanding = nil
    }

    /// The Mac woke from sleep: wall-clock time spent asleep is neither idle
    /// nor capture time. Restarts the grace and any threshold in progress.
    mutating func clockResumed(at now: Date) {
        if idleSince != nil { idleSince = now }
        for id in apps.keys where apps[id]?.capturingSince != nil && apps[id]?.runQualified == false {
            apps[id]?.capturingSince = now
            apps[id]?.lastSeen = now
        }
    }

    private mutating func qualify(at now: Date, active: Set<String>) {
        for id in apps.keys.sorted() {
            guard let tracked = apps[id], let since = tracked.capturingSince, !tracked.runQualified else { continue }
            let end = active.contains(id) ? now : (tracked.lastSeen ?? since)
            guard end.timeIntervalSince(since) >= tracked.app.threshold else { continue }
            apps[id]?.runQualified = true
            apps[id]?.watched = true
            armed = true
            outstanding = nil // the call is back (or another one started)
        }
    }

    /// When, with no change in observations, the clock alone would change
    /// something: a capture reaching its threshold (re-arms, withdraws a
    /// prompt) or the grace running out. Nil = nothing to time.
    func nextDeadline(_ context: Context) -> Date? {
        guard context.enabled else { return nil }
        var deadlines = apps.values.compactMap { tracked in
            tracked.runQualified ? nil : tracked.capturingSince?.addingTimeInterval(tracked.app.threshold)
        }
        if armed, !context.promptVisible, let idleSince { deadlines.append(idleSince.addingTimeInterval(Self.grace)) }
        return deadlines.min()
    }

    /// Some meeting app (watched or still below its threshold) captures
    /// input. The driver rescans periodically only then: Core Audio does not
    /// notify `IsRunningInput` changes, and while quill records the input
    /// device keeps running, so a hang-up may produce no event at all.
    var isTrackingCapture: Bool { apps.values.contains { $0.capturingSince != nil } }

    /// The watched app that released the input last (for logs).
    var lastReleasedApp: MeetingApp? { lastReleased }

    /// Call after `step`.
    func status(_ context: Context) -> Status {
        guard context.enabled else { return .disabled }
        let watched = apps.filter(\.value.watched)
        if watched.isEmpty { return .notWatching }
        let capturing = watched.filter { $0.value.capturingSince != nil }.keys.sorted()
        if !capturing.isEmpty { return .capturing(capturing) }
        guard armed, let idleSince else { return .disarmed }
        return .grace(elapsed: min(context.now.timeIntervalSince(idleSince), Self.grace), grace: Self.grace)
    }
}
