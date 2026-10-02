import Foundation

/// The memory status of one session for the main window and the
/// sessions menu, derived only from
/// `HindsightFacts` plus config — no state of its own, so it always agrees
/// with what `HindsightCoordinator` would do on its next look. Pure.
enum HindsightStatus: Sendable, Equatable {
    /// A v2 `hindsight.json` for the current transcript content, and the
    /// bank it is in (a record without one → the default bank).
    case sent(Date, bank: String?)
    /// Requested or automatic, not in memory yet (not ready, offline, or a
    /// changed transcript waiting to be resent).
    case pending
    /// `hindsight.error`, or pending while sends are paused on a token.
    case error
    /// Under the threshold and neither requested nor sent.
    case short
    /// Sendable, not sent, not requested.
    case notSent
    /// `hindsight.omitir`.
    case omitted

    /// The button (window) / item (menu) each status offers.
    enum Action: Sendable, Equatable {
        /// "Enviar a memoria" (also lifts `hindsight.omitir`).
        case send
        /// "Enviar igual" for a short session.
        case sendAnyway
        /// "Reenviar a memoria": forced resend.
        case resend
        /// "Reintentar envío".
        case retry

        var title: String {
            switch self {
            case .send: Textos.Memoria.enviar
            case .sendAnyway: Textos.Memoria.enviarIgual
            case .resend: Textos.Memoria.reenviar
            case .retry: Textos.Memoria.reintentarEnvio
            }
        }

        /// "Enviar a memoria ▸ <banco>": only a first send picks a bank; a
        /// resend or retry always goes to the session's recorded bank.
        var choosesBank: Bool { self == .send || self == .sendAnyway }

        /// Whether the session, as the disk says **now**, still offers this
        /// action: a menu can stay open (or a window unrefreshed) while the
        /// session is sent, requested or omitted, and acting on the old
        /// offer would send twice or undo the user's "No enviar".
        ///
        /// `omitted` is deliberate state: only a row that showed it as
        /// omitted (`shown`) may lift it by sending; a menu built for a
        /// sendable session must not send one the user has omitted since.
        func isStillOffered(by live: HindsightStatus?, shownAs shown: HindsightStatus? = nil) -> Bool {
            guard let live, live.action == self else { return false }
            if live == .omitted { return shown == .omitted }
            return true
        }
    }

    /// The config the derivation needs.
    struct Settings: Sendable, Equatable {
        let enabled: Bool
        let autoSend: Bool
        let since: String?
        let minWords: Int
        let minMinutes: Int
        let defaultBank: String?

        init(enabled: Bool, autoSend: Bool, since: String?, minWords: Int, minMinutes: Int, defaultBank: String? = nil) {
            self.enabled = enabled
            self.autoSend = autoSend
            self.since = since
            self.minWords = minWords
            self.minMinutes = minMinutes
            self.defaultBank = defaultBank
        }

        init(config: ConfigValues) {
            self.init(
                enabled: config.hindsightEnabled, autoSend: config.hindsightAutoSend, since: config.hindsightSince,
                minWords: config.hindsightMinWords, minMinutes: config.hindsightMinMinutes, defaultBank: config.hindsightBank
            )
        }
    }

    var action: Action {
        switch self {
        case .sent: .resend
        case .pending, .error: .retry
        case .short: .sendAnyway
        case .notSent, .omitted: .send
        }
    }

    /// - Returns: nil when nothing is shown: integration off, facts not
    ///   read, or no transcript. Precedence: omitted > sent (current
    ///   content, no request outstanding) > error > pending (subscribed or
    ///   auto-eligible — including a sent session with an outstanding
    ///   request, forced or not; error while paused) > short > not sent.
    static func derive(
        facts: HindsightFacts?, settings: Settings, timeZone: TimeZone, authPaused: Bool
    ) -> HindsightStatus? {
        guard settings.enabled, let facts, facts.hasTranscript else { return nil }
        if facts.skipped { return .omitted }
        // A request outstanding for an already-sent session — a forced
        // resend, or a plain one not yet drained — must show as pending,
        // not as still "En memoria" for content that's about to change.
        if facts.isSentCurrent, facts.request == nil, let sent = facts.sent {
            return .sent(sent.sentAt, bank: sent.bank ?? settings.defaultBank)
        }
        if facts.failed { return .error }
        if facts.isSubscribed || autoEligible(facts, settings, timeZone) { return authPaused ? .error : .pending }
        if facts.isShort(minWords: settings.minWords, minMinutes: settings.minMinutes) { return .short }
        return .notSent
    }

    private static func autoEligible(_ facts: HindsightFacts, _ settings: Settings, _ timeZone: TimeZone) -> Bool {
        guard settings.autoSend, let since = settings.since, let started = facts.started else { return false }
        return ConfigValues.hindsightDay(started, timeZone: timeZone) >= since
            && !facts.isShort(minWords: settings.minWords, minMinutes: settings.minMinutes)
    }
}
