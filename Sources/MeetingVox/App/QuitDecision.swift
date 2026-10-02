import Foundation

/// What ⌘Q and the menu bar's Salir do first (quit while
/// recording, plus the unsaved template draft). Pure. It is only about asking: the actual exit always goes
/// through `NSApp.terminate`, so `AppDelegate.applicationShouldTerminate` and
/// `TerminationPolicy` still finalize a live recording. Signals, logout and
/// `launchctl bootout` never come through here, so they never show UI.
enum QuitDecision: Equatable {
    /// Nothing to lose: quit at once.
    case terminate
    /// A recording is in progress: ask "¿Detener y salir?" first.
    case confirm

    static func decide(isRecording: Bool) -> QuitDecision {
        isRecording ? .confirm : .terminate
    }

    /// The user's answer to the confirmation.
    enum Answer: Equatable {
        case stopAndQuit
        case cancel

        /// `NSAlert` reports the button that was pressed by its position
        /// (0 = first added). The destructive choice is the first one, so
        /// anything unexpected must fall to `cancel`.
        init(buttonIndex: Int) {
            self = buttonIndex == 0 ? .stopAndQuit : .cancel
        }

        var terminates: Bool { self == .stopAndQuit }
    }
}

/// Who is asking the app to quit, as far as the current Apple event says.
/// The Dock menu's Quit (and `tell application "MeetingVox" to quit`) reaches
/// `applicationShouldTerminate` **without** going through `requestQuit`, so
/// the delegate has to tell it apart from the system quitting us.
enum QuitOrigin: Equatable {
    /// A quit Apple event with no reason: a person chose Quit somewhere that
    /// is not our own menu (the Dock).
    case userAppleEvent
    /// A quit Apple event that carries a reason (logout, restart, shutdown,
    /// "quit all"): never any UI, or a shutdown would hang on our alert.
    case system
    /// No quit event: a signal (SIGTERM, `launchctl bootout`) or our own
    /// `NSApp.terminate` after `requestQuit` confirmed.
    case programmatic

    /// 'aevt' / 'quit': `kCoreEventClass` / `kAEQuitApplication`.
    static let coreEventClass: UInt32 = 0x6165_7674
    static let quitApplication: UInt32 = 0x7175_6974

    /// - Parameters:
    ///   - eventClass, eventID: of `NSAppleEventManager.currentAppleEvent`
    ///     (nil when none is being handled).
    ///   - reason: the `kAEQuitReason` ('why?') enum code, nil when absent.
    static func classify(eventClass: UInt32?, eventID: UInt32?, reason: UInt32?) -> QuitOrigin {
        guard eventClass == coreEventClass, eventID == quitApplication else { return .programmatic }
        // Any reason at all — including ones this list does not know — is the
        // system: the safe side is to never block it.
        return reason == nil ? .userAppleEvent : .system
    }
}

extension QuitDecision {
    /// What `applicationShouldTerminate` does before finalizing anything.
    enum Gate: Equatable {
        /// Carry on with `TerminationPolicy`.
        case allow
        /// Cancel this termination and ask first (recording, unsaved
        /// template); the confirmed answers terminate again through
        /// `requestQuit`.
        case askFirst
    }

    /// Only a person quitting from outside our own menus, with something to
    /// lose (a recording, an unsaved template), and not yet confirmed, is
    /// asked. Everything else — logout, restart, shutdown, SIGTERM,
    /// `launchctl bootout` — must never show UI.
    static func atTermination(
        isRecording: Bool, hasDraft: Bool = false, origin: QuitOrigin, alreadyConfirmed: Bool
    ) -> Gate {
        (isRecording || hasDraft) && origin == .userAppleEvent && !alreadyConfirmed ? .askFirst : .allow
    }

    // MARK: - Questions and the unsaved template

    /// One thing the person must answer before the app quits.
    enum Question: Equatable {
        /// "Hay una grabación en curso. ¿Detener y salir?"
        case stopRecording
        /// "Hay cambios sin guardar en la plantilla X": Guardar / Descartar / Cancelar.
        case saveDraft(String)
    }

    /// Everything to ask, in order: the recording first (it is the one that
    /// cannot be redone), then the template draft. Empty = quit at once.
    static func questions(isRecording: Bool, draft: String?) -> [Question] {
        var questions: [Question] = []
        if isRecording { questions.append(.stopRecording) }
        if let draft { questions.append(.saveDraft(draft)) }
        return questions
    }

    /// The answer to the draft question.
    enum DraftAnswer: Equatable {
        case save
        case discard
        case cancel

        /// `NSAlert` buttons by position: Guardar, Descartar, Cancelar.
        /// Anything unexpected falls to `cancel`, the safe side.
        init(buttonIndex: Int) {
            switch buttonIndex {
            case 0: self = .save
            case 1: self = .discard
            default: self = .cancel
            }
        }

        /// Whether the quit goes on. Saving only counts when the save worked
        /// (a conflict or a write error keeps the app open to show it).
        func proceeds(saved: Bool) -> Bool {
            switch self {
            case .save: saved
            case .discard: true
            case .cancel: false
            }
        }
    }
}
