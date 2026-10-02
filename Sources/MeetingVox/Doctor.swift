import AVFoundation
import FluidAudio
import Foundation

enum CheckStatus {
    case ok
    case warn(String)
    case fail(String)
}

struct Check {
    let name: String
    let status: CheckStatus
    let remediation: String?
}

enum DoctorReport {
    static func run(recordingsRoot: URL) -> [Check] {
        let config = Config.values()
        return [
            checkMicrophone(),
            checkSystemAudio(),
            checkRecordingsRoot(recordingsRoot),
            checkTranscription(),
        ] + checkMinutes()
            + checkHindsight(config: config, hasToken: Keychain.hindsight.hasAPIKey())
            + checkCalendar(
                enabled: config.calendarEnabled,
                isBundled: NotifierFactory.currentKind == .userNotifications,
                status: EventKitCalendarSource.currentStatus())
    }

    /// The calendar link is opt-in: disabled adds no row. Enabled outside
    /// MeetingVox.app EventKit is never touched (the status is not even read:
    /// it is an autoclosure), so it only warns. In the bundled app it warns
    /// when the OS access is missing. Never `.fail`, never requests.
    static func checkCalendar(
        enabled: Bool, isBundled: Bool, status: @autoclosure () -> CalendarSystemStatus
    ) -> [Check] {
        guard enabled else { return [] }
        guard isBundled else {
            return [Check(
                name: "calendar",
                status: .warn("cannot be read outside MeetingVox.app"),
                remediation: "run MeetingVox.app (the calendar is only read by the bundled app)"
            )]
        }
        switch status() {
        case .authorized:
            return [Check(name: "calendar", status: .ok, remediation: nil)]
        case .notDetermined:
            return [Check(
                name: "calendar",
                status: .warn("calendar.enabled is on but macOS has not been asked yet"),
                remediation: "\(Textos.Menu.configuracion) → \(Textos.Ajustes.pestanaReuniones) → \(Textos.Calendario.seccion): turn it off and on again"
            )]
        case .denied, .writeOnly, .restricted, .unavailable:
            return [Check(
                name: "calendar",
                status: .warn("calendar.enabled is on but macOS does not allow reading the calendar — titles are not linked"),
                remediation: "System Settings → Privacy & Security → Calendarios → enable MeetingVox (full access)"
            )]
        }
    }

    /// Never `.fail`: a denied microphone must not abort startup. The system
    /// audio track still records alone (`RecordingSession` degrades per
    /// track), and a menu-bar app that exits silently looks broken. The status
    /// is a parameter so the mapping is testable.
    static func checkMicrophone(
        status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    ) -> Check {
        switch status {
        case .authorized:
            return Check(name: "microphone", status: .ok, remediation: nil)
        case .notDetermined:
            return Check(
                name: "microphone",
                status: .warn("not yet requested — will prompt on first recording"),
                remediation: "start a recording once; macOS will prompt"
            )
        case .denied, .restricted:
            return Check(
                name: "microphone",
                status: .warn("denied — only system audio will be recorded"),
                remediation: "System Settings → Privacy & Security → Microphone → enable for MeetingVox (or your terminal)"
            )
        @unknown default:
            return Check(
                name: "microphone",
                status: .warn("unknown authorization state — the microphone track may not record"),
                remediation: nil
            )
        }
    }

    /// There is no public API to query the system-audio-capture TCC state
    /// without side effects, so all we can do is describe the flow.
    static func checkSystemAudio() -> Check {
        Check(
            name: "system audio",
            status: .warn("state unknowable until first use — will prompt on first recording"),
            remediation: "if recordings come out silent: System Settings → Privacy & Security → Screen & System Audio Recording"
        )
    }

    static func checkRecordingsRoot(_ root: URL) -> Check {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            return Check(
                name: "recordings folder",
                status: .fail("can't create \(root.path)"),
                remediation: "check permissions on the parent directory"
            )
        }
        guard FileManager.default.isWritableFile(atPath: root.path) else {
            return Check(
                name: "recordings folder",
                status: .fail("\(root.path) is not writable"),
                remediation: "check permissions on the directory"
            )
        }
        return Check(name: "recordings folder", status: .ok, remediation: nil)
    }

    /// Never discover a missing model after an important meeting: report
    /// whether the parakeet models are already in FluidAudio's cache.
    static func checkTranscription() -> Check {
        guard Config.transcriptionEnabled() else {
            return Check(
                name: "transcription",
                status: .warn("disabled in config"),
                remediation: nil
            )
        }
        let cache = AsrModels.defaultCacheDirectory(for: .ultra)
        if AsrModels.modelsExist(at: cache, version: .ultra) {
            return Check(name: "transcription", status: .ok, remediation: nil)
        }
        return Check(
            name: "transcription",
            status: .warn("parakeet models not downloaded (~750 MB)"),
            remediation: "downloads automatically on first transcription — record a short test session while online"
        )
    }

    /// Minutes are opt-in and need both an OpenRouter key and a model. Only
    /// ever `.warn`: a missing key must not stop recording. `hasAPIKey()`
    /// queries attributes only, so this never raises a Keychain prompt at
    /// login.
    static func checkMinutes() -> [Check] {
        guard Config.minutesEnabled() else {
            return [Check(name: "minutes", status: .ok, remediation: nil)]
        }
        var checks: [Check] = []
        if !Keychain.openRouter.hasAPIKey() {
            checks.append(Check(
                name: "minutes api key",
                status: .warn("minutes enabled but no OpenRouter API key in the Keychain"),
                remediation: "menu bar → \(Textos.Menu.configuracion) → \(Textos.Ajustes.pestanaOpenRouter) → save an API key"
            ))
        }
        if Config.openRouterModel() == nil {
            checks.append(Check(
                name: "minutes model",
                status: .warn("minutes enabled but no OpenRouter model selected"),
                remediation: "menu bar → \(Textos.Menu.configuracion) → \(Textos.Ajustes.pestanaOpenRouter) → pick a model"
            ))
        }
        return checks.isEmpty ? [Check(name: "minutes", status: .ok, remediation: nil)] : checks
    }

    /// The Hindsight integration is opt-in; when on, report what it still
    /// needs. The cutoff only matters for the automatic send. Only `.warn` —
    /// a missing token must never stop recording — and the Keychain lookup
    /// is attributes-only, so it never prompts at login.
    static func checkHindsight(config: ConfigValues, hasToken: Bool) -> [Check] {
        guard config.hindsightEnabled else { return [Check(name: "hindsight", status: .ok, remediation: nil)] }
        let settings = "menu bar → \(Textos.Menu.configuracion) → \(Textos.Memoria.pestana)"
        var checks: [Check] = []
        if !hasToken {
            checks.append(Check(
                name: "hindsight token",
                status: .warn("integration enabled but no Hindsight token in the Keychain"),
                remediation: "\(settings) → save the token"
            ))
        }
        if config.hindsightBaseURL == nil {
            checks.append(Check(
                name: "hindsight url",
                status: .warn("integration enabled but hindsight.base_url is missing or not an http(s) URL"),
                remediation: "\(settings) → server URL"
            ))
        }
        if config.hindsightBank == nil {
            checks.append(Check(
                name: "hindsight bank",
                status: .warn("integration enabled but hindsight.bank is missing"),
                remediation: "\(settings) → memory bank"
            ))
        }
        if config.hindsightAutoSend, config.hindsightSince == nil {
            checks.append(Check(
                name: "hindsight since",
                status: .warn("auto_send is on but hindsight.since is missing or not yyyy-MM-dd — nothing is sent automatically"),
                remediation: "\(settings) → pick the first day to send automatically"
            ))
        }
        return checks.isEmpty ? [Check(name: "hindsight", status: .ok, remediation: nil)] : checks
    }

    static func print(_ checks: [Check]) {
        for c in checks {
            let (mark, label): (String, String) = {
                switch c.status {
                case .ok: return ("✓", "ok")
                case .warn(let msg): return ("!", msg)
                case .fail(let msg): return ("✗", msg)
                }
            }()
            Swift.print("\(mark) \(c.name): \(label)")
            if let r = c.remediation {
                Swift.print("    → \(r)")
            }
        }
    }

    /// True if no checks are in a hard-fail state. Warnings don't block.
    static func allOK(_ checks: [Check]) -> Bool {
        checks.allSatisfy {
            if case .fail = $0.status { return false }
            return true
        }
    }
}
