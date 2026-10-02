import Testing

@testable import MeetingVox

/// The mapping from what the system reports to a row's status, action and
/// note. Pure: the views stay presentational and every input combination is
/// covered here without asking the system for anything.
@Suite("PermissionStatus")
struct PermissionStatusTests {
    private func row(_ status: PermissionStatus, _ action: RowAction, _ note: PermissionNote? = nil) -> PermissionRow {
        PermissionRow(status: status, action: action, note: note)
    }

    // MARK: - Microphone (any AV/UN authorization)

    @Test func authorizedIsGrantedWithNothingToDo() {
        #expect(PermissionStatus.mapAuthorization(.authorized, pane: .microphone, requestedThisRun: false)
            == row(.granted, .none))
        // Already granted stays granted even after a click this run.
        #expect(PermissionStatus.mapAuthorization(.authorized, pane: .microphone, requestedThisRun: true)
            == row(.granted, .none))
    }

    @Test func undeterminedOffersPermitirUntilAskedThisRun() {
        #expect(PermissionStatus.mapAuthorization(.notDetermined, pane: .microphone, requestedThisRun: false)
            == row(.notDetermined, .allow))
        // Asked, and the system still has no answer: point at the settings.
        #expect(PermissionStatus.mapAuthorization(.notDetermined, pane: .microphone, requestedThisRun: true)
            == row(.requested, .openSettings(.microphone)))
    }

    @Test func deniedOpensThePaneOfTheRow() {
        #expect(PermissionStatus.mapAuthorization(.denied, pane: .microphone, requestedThisRun: false)
            == row(.denied, .openSettings(.microphone)))
        #expect(PermissionStatus.mapAuthorization(.denied, pane: .notifications, requestedThisRun: true)
            == row(.denied, .openSettings(.notifications)))
    }

    @Test func restrictedIsDeniedWithAPolicyNote() {
        #expect(PermissionStatus.mapAuthorization(.restricted, pane: .microphone, requestedThisRun: false)
            == row(.denied, .openSettings(.microphone), .restrictedByPolicy))
    }

    // MARK: - Notifications

    @Test func notificationsMapLikeAnyAuthorization() {
        #expect(PermissionStatus.mapNotifications(.authorized, requestedThisRun: false) == row(.granted, .none))
        #expect(PermissionStatus.mapNotifications(.notDetermined, requestedThisRun: false) == row(.notDetermined, .allow))
        #expect(PermissionStatus.mapNotifications(.denied, requestedThisRun: false)
            == row(.denied, .openSettings(.notifications)))
    }

    @Test func notificationsOutsideTheBundledAppAreNotApplicable() {
        #expect(PermissionStatus.mapNotifications(nil, requestedThisRun: false)
            == row(.notApplicable, .none, .unavailableOutsideApp))
        #expect(PermissionStatus.mapNotifications(nil, requestedThisRun: true)
            == row(.notApplicable, .none, .unavailableOutsideApp))
    }

    // MARK: - System audio

    @Test func systemAudioGrantedNeedsNothingEvenWhileRecording() {
        #expect(PermissionStatus.mapSystemAudio(tcc: .granted, requestedThisRun: false, isRecording: false)
            == row(.granted, .none))
        #expect(PermissionStatus.mapSystemAudio(tcc: .granted, requestedThisRun: false, isRecording: true)
            == row(.granted, .none))
    }

    @Test func systemAudioDeniedOpensItsPaneEvenWhileRecording() {
        #expect(PermissionStatus.mapSystemAudio(tcc: .denied, requestedThisRun: false, isRecording: false)
            == row(.denied, .openSettings(.systemAudio)))
        #expect(PermissionStatus.mapSystemAudio(tcc: .denied, requestedThisRun: true, isRecording: true)
            == row(.denied, .openSettings(.systemAudio)))
    }

    @Test func systemAudioUnknownOffersPermitirBeforeTheClick() {
        #expect(PermissionStatus.mapSystemAudio(tcc: .unknown, requestedThisRun: false, isRecording: false)
            == row(.notDetermined, .allow))
        // The prompt cannot be pre-triggered while a recording runs.
        #expect(PermissionStatus.mapSystemAudio(tcc: .unknown, requestedThisRun: false, isRecording: true)
            == row(.notDetermined, .waitForRecordingEnd, .recordingInProgress))
    }

    @Test func systemAudioStillUnknownAfterTheClickIsSolicitado() {
        #expect(PermissionStatus.mapSystemAudio(tcc: .unknown, requestedThisRun: true, isRecording: false)
            == row(.requested, .openSettings(.systemAudio)))
        // A click before the recording started still shows what happened.
        #expect(PermissionStatus.mapSystemAudio(tcc: .unknown, requestedThisRun: true, isRecording: true)
            == row(.requested, .openSettings(.systemAudio)))
    }

    @Test func systemAudioWithoutTheSPIBecomesSolicitadoOnceClicked() {
        // No way to read the status: before the click there is nothing to say
        // but "Permitir"; after it the honest answer is "Solicitado".
        #expect(PermissionStatus.mapSystemAudio(tcc: nil, requestedThisRun: false, isRecording: false)
            == row(.notDetermined, .allow))
        #expect(PermissionStatus.mapSystemAudio(tcc: nil, requestedThisRun: true, isRecording: false)
            == row(.requested, .openSettings(.systemAudio)))
        #expect(PermissionStatus.mapSystemAudio(tcc: nil, requestedThisRun: false, isRecording: true)
            == row(.notDetermined, .waitForRecordingEnd, .recordingInProgress))
    }

    // MARK: - Local network

    @Test func localNetworkIsNotApplicableWithoutHindsight() {
        for probe in [nil, LocalNetworkProbe.Result.reachable, .prohibited, .unreachable] {
            #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: false, probe: probe, probeRequested: true)
                == row(.notApplicable, .none, .whenMemoryEnabled))
        }
    }

    @Test func localNetworkIsAskedOnlyByAClick() {
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: nil, probeRequested: false)
            == row(.notDetermined, .allow))
        // Clicked, the probe has not answered yet.
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: nil, probeRequested: true)
            == row(.requested, .none))
    }

    @Test func localNetworkFollowsTheProbeResult() {
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: .reachable, probeRequested: true)
            == row(.granted, .none))
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: .prohibited, probeRequested: true)
            == row(.denied, .openSettings(.localNetwork)))
        // Timed out after the click: the prompt may still be waiting.
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: .pending, probeRequested: true)
            == row(.requested, .allow))
        // Not the permission's fault: the server did not answer. Allow a retry.
        #expect(PermissionStatus.mapLocalNetwork(hindsightEnabled: true, probe: .unreachable, probeRequested: true)
            == row(.requested, .allow, .serverUnreachable))
    }
}
