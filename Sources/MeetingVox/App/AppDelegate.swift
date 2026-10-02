import AppKit

/// The one place AppKit asks "may I quit?". ⌘Q, the menu's Quit, SIGTERM and
/// SIGINT (both routed to `NSApp.terminate` in `Run`), logout and
/// `launchctl bootout` all arrive here, and `TerminationPolicy` decides (after
/// `QuitDecision.atTermination` has sent a Dock-menu Quit through the
/// recording confirmation).
///
/// A live recording is stopped synchronously before we reply, so `meta.json`
/// exists when the process goes away and the transcription queue picks the
/// session up at the next launch. Stopping inside a signal handler is not an
/// option (not async-signal-safe), hence the dispatch source in `Run`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller: AppController
    private var terminating = false
    /// The notification center keeps its delegate weakly.
    private lazy var notificationResponder = NotificationResponder { [weak controller] action in
        controller?.perform(action)
    }

    init(controller: AppController) {
        self.controller = controller
    }

    /// Before launch finishes, so a notice tapped while the app was closed
    /// (which launches it) reaches `notificationResponder`. Bundled app only:
    /// touching the notification center from a bare binary crashes.
    func applicationWillFinishLaunching(_ notification: Notification) {
        guard NotifierFactory.currentKind == .userNotifications else { return }
        UserNotificationsSetup.install(delegate: notificationResponder)
    }

    /// The onboarding window (when the gate said so) opens now that the app
    /// is running.
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.launchFinished()
    }

    /// The Apple event being handled right now, as `QuitOrigin` sees it. The
    /// Dock menu's Quit arrives as a reasonless quit event; logout, restart
    /// and shutdown carry a reason; a signal or our own `terminate` has none.
    private func currentQuitOrigin() -> QuitOrigin {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let reason = event?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)).map(\.enumCodeValue)
        return QuitOrigin.classify(eventClass: event?.eventClass, eventID: event?.eventID, reason: reason)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A person choosing Quit from the Dock bypasses `requestQuit`: cancel
        // this termination and ask first. Logout, shutdown, signals and
        // bootout never reach the alert (`QuitDecision.atTermination`).
        let gate = QuitDecision.atTermination(
            isRecording: controller.isRecording, hasDraft: controller.hasTemplateDraft,
            origin: currentQuitOrigin(), alreadyConfirmed: controller.quitConfirmed
        )
        if gate == .askFirst {
            // Next turn: an alert run from inside this callback would nest.
            DispatchQueue.main.async { [controller] in
                MainActor.assumeIsolated { controller.requestQuit() }
            }
            return .terminateCancel
        }
        switch TerminationPolicy.decide(isRecording: controller.isRecording, alreadyTerminating: terminating) {
        case .now:
            controller.prepareForTermination()
            return .terminateNow
        case .stopThenLater(let drain):
            terminating = true
            FileHandle.standardError.write(Data("finalizing the recording before quitting\n".utf8))
            controller.prepareForTermination()
            // GCD main-queue work runs in the modal run-loop mode AppKit uses
            // while a termination is deferred; a `Timer` would not.
            DispatchQueue.main.asyncAfter(deadline: .now() + drain) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            return .terminateLater
        case .alreadyInProgress:
            // The reply already scheduled is the one that ends the app.
            return .terminateLater
        }
    }

    /// Launching the app again (Finder, Spotlight) when it is already running
    /// has no window to bring forward: open the main window instead.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.showMainWindow()
        return false
    }
}
