import AVFoundation
import Foundation

extension Diag {
    /// `--mode permissions`: prints the status of every permission this
    /// process can read **without asking**. It requests nothing, creates no
    /// tap or aggregate device, probes no network, registers no login item
    /// and touches no Keychain item. Reads only: the AV authorization
    /// status, the private TCC preflight, the notification settings (bundled
    /// only), the login item statuses (bundled only), the onboarding marker.
    /// The speech-model line is a presence check only (nothing is downloaded
    /// or loaded). The key lines are attribute-only Keychain lookups
    /// (`presence()`): the secret is never read, so nothing can prompt.
    ///
    /// From a terminal, TCC attributes microphone and system audio to the
    /// terminal, not to MeetingVox: run it from the bundled app for the
    /// app's own answers.
    func runPermissions() {
        let say: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
        let kind = NotifierFactory.currentKind
        let bundled = kind == .userNotifications
        let home = FileManager.default.homeDirectoryForCurrentUser
        say("MeetingVox diag · mode=permissions · read-only: nothing is requested, no tap is created, no network is probed")
        say("bundled: \(bundled)")
        if let terminal = Self.hostTerminal() {
            say("note: launched from \(terminal); microphone and system-audio TCC answers are for that host, not for MeetingVox")
        }

        // Microphone: the AV status only.
        let microphone = SystemAuthorization(av: AVCaptureDevice.authorizationStatus(for: .audio))
        say("microphone: \(microphone)")
        let micRow = PermissionStatus.mapAuthorization(microphone, pane: .microphone, requestedThisRun: false)
        say("  row: \(Self.describe(micRow))")

        // System audio: the private preflight, read-only.
        let tcc = TCCBridge.live
        say("system audio TCC SPI: \(tcc.isAvailable ? "available" : "MISSING (row reads Solicitado once clicked)")")
        let preflight = tcc.preflightAudioCapture()
        say("system audio preflight (\(TCCBridge.audioCaptureService)): \(preflight.map { "\($0)" } ?? "not readable")")
        let systemRow = PermissionStatus.mapSystemAudio(tcc: preflight, requestedThisRun: false, isRecording: false)
        say("  row: \(Self.describe(systemRow))")

        // Notifications: never touch the center unbundled (it crashes).
        if bundled {
            say("notifications: \(Self.readNotificationAuthorization().map { "\($0)" } ?? "no answer within 10 s")")
        } else {
            say("notifications: not touched (unbundled process)")
        }

        // Local Network: the probe itself raises the prompt.
        let values = Config.values()
        say("local network: not probed (a probe raises the Local Network prompt)"
            + "; hindsight.enabled=\(values.hindsightEnabled) base_url=\(values.hindsightBaseURL?.absoluteString ?? "unset")")
        let lanRow = PermissionStatus.mapLocalNetwork(
            hindsightEnabled: values.hindsightEnabled, probe: nil, probeRequested: false
        )
        say("  row: \(Self.describe(lanRow))")

        // Login items.
        if bundled {
            say("login item service: \(AgentServiceLoginItem().status)")
        } else {
            say("login item service: not read (unbundled process)")
        }
        say("login item fallback file: \(LaunchAgentFileLoginItem(home: home).status)")

        // Calendar: the class-level status, bundled only; never requests.
        say(Self.calendarLine(
            enabled: values.calendarEnabled, bundled: bundled, status: EventKitCalendarSource.currentStatus()))

        // Speech model: presence only, a read of FluidAudio's cache layout.
        say(Self.modelPresenceLine(FluidAudioModelDownloader()))

        // Secrets: attributes only, never the value.
        say(Self.keyPresenceLine("OpenRouter key", Keychain.openRouter))
        say(Self.keyPresenceLine("Hindsight token", Keychain.hindsight))

        // Marker and gate.
        let markerURL = AppIdentity.onboardingMarkerFile(home: home)
        let marker = OnboardingMarker.read(at: markerURL)
        say("onboarding marker: \(markerURL.path) → \(marker)")
        let decision = OnboardingGate.decide(
            isBundled: bundled, isRunRoute: true, marker: marker,
            hasExistingConfig: FileManager.default.fileExists(atPath: Config.path.path)
        )
        say("onboarding gate (if launched with `run`): \(decision) [current version \(OnboardingGate.currentVersion)]")
    }

    /// One line about the calendar. The status is read only from the bundled
    /// app (an autoclosure, so it is not even evaluated otherwise); nothing is
    /// requested and no store is created.
    static func calendarLine(enabled: Bool, bundled: Bool, status: @autoclosure () -> CalendarSystemStatus) -> String {
        let prefix = "calendar: calendar.enabled=\(enabled)"
        guard bundled else { return prefix + "; not read (unbundled process)" }
        return prefix + "; status=\(status()) (read-only: nothing is requested)"
    }

    /// One line about the speech model. Asks the downloader for presence only:
    /// no download, no load, no write.
    static func modelPresenceLine(_ downloader: some ModelDownloader) -> String {
        downloader.isPresent()
            ? "speech model: present at \(downloader.directory.path)"
            : "speech model: not downloaded (expected at \(downloader.directory.path)); nothing is downloaded by diag"
    }

    /// One line about where a secret lives. `presence()` is attribute-only;
    /// `read()` (which can raise the legacy Keychain prompt) is never called.
    static func keyPresenceLine(_ label: String, _ store: some APIKeyStore) -> String {
        switch store.presence() {
        case .primary:
            "\(label): primary (MeetingVox service; attributes only, never read)"
        case .legacyOnly:
            "\(label): legacyOnly (only under the legacy quill service; onboarding offers \"Migrar clave\"; attributes only, never read)"
        case .none:
            "\(label): none (attributes only, never read)"
        }
    }

    private static func describe(_ row: PermissionRow) -> String {
        "status=\(row.status) action=\(row.action)" + (row.note.map { " note=\($0)" } ?? "")
    }

    /// Bundled only: blocks up to 10 s on the notification settings read.
    private static func readNotificationAuthorization() -> SystemAuthorization? {
        final class Box: @unchecked Sendable { var value: SystemAuthorization? }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await LivePermissionProbes.notifications()
            done.signal()
        }
        return done.wait(timeout: .now() + 10) == .success ? box.value : nil
    }
}
