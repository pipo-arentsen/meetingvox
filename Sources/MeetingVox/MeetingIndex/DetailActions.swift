import Foundation

/// The contents of the session detail's toolbar as data: "Regenerar ▾",
/// "Enviar a memoria ▾" and "⋯". Pure, so every menu decision —
/// what is disabled and why, which banks, whether skipping is offered — is a
/// test, and the SwiftUI view only draws it.
///
/// It carries the intents of the retired sessions menu's per-session submenu
/// (`HindsightBankMenu` remains the bank source).
struct DetailActions: Equatable, Sendable {
    /// What the builder needs, all plain values.
    struct Input: Sendable {
        var hasTranscript: Bool
        /// `transcript.md` exists: the file "Abrir transcripción" opens.
        var hasTranscriptMD: Bool
        var hasMinutes: Bool
        /// `minuta.pendiente` or `minuta.error`: automatic minutes still owed.
        var minutesOwed: Bool
        /// Template ids of the manual `minuta.<id>.md` files, sorted.
        var manualMinutes: [String]
        var templates: [MinutesTemplate]
        /// Why minutes cannot run now (no key / no model); nil when they can.
        var minutesUnavailableReason: String?
        /// `HindsightStatus.derive`; nil = integration off or no transcript.
        var memory: HindsightStatus?
        /// A memory send for this session was dispatched and has not reported back.
        var memoryInFlight: Bool
        var defaultBank: String?
        var otherBanks: [String]
        /// meta.json has a `calendar_event`: "Quitar evento del calendario" is offered.
        var hasCalendarEvent: Bool = false
    }

    // MARK: Regenerar ▾

    struct TemplateChoice: Equatable, Sendable {
        let id: String
        let title: String
        let tooltip: String?
    }

    /// A submenu that either lists templates or says (disabled) why not.
    enum TemplateChoices: Equatable, Sendable {
        case choices([TemplateChoice])
        case unavailable(String)

        var choices: [TemplateChoice] {
            if case .choices(let list) = self { return list }
            return []
        }
    }

    /// "Reintentar minuta" (automatic minutes owed).
    struct Retry: Equatable, Sendable {
        let isEnabled: Bool
        /// The reason it is disabled.
        let tooltip: String?
    }

    struct Regenerate: Equatable, Sendable {
        /// Only for a session whose automatic minutes are owed.
        let retry: Retry?
        /// "Regenerar minuta con ▸": only when `minuta.md` and a transcript exist.
        let regenerateWith: TemplateChoices?
        /// "Generar minuta con… ▸" (manual `minuta.<id>.md`): always present.
        let generateWith: TemplateChoices
    }

    // MARK: Enviar a memoria ▾

    struct BankChoice: Equatable, Sendable {
        let title: String
        /// nil selects the default bank.
        let bank: String?
        /// Drawn checked.
        let isDefault: Bool
    }

    /// The stepper's "Enviar": one click, the default bank (else the first
    /// known one), for a sendable session that has not been sent.
    struct QuickSend: Equatable, Sendable {
        let action: HindsightStatus.Action
        /// nil selects the default bank.
        let bank: String?
    }

    struct Memory: Equatable, Sendable {
        /// The status the button was built for. The re-check on click compares
        /// it with the disk (`Action.isStillOffered(by:shownAs:)`).
        let status: HindsightStatus
        let action: HindsightStatus.Action
        var title: String { action.title }
        /// The banks to pick from; nil = a plain item.
        let banks: [BankChoice]?
        /// False for a first send when no bank is known at all (it would
        /// resolve to nothing) and while a send is in flight (no double
        /// dispatch); it must not look clickable either way.
        let isEnabled: Bool
        /// nil unless the session is sendable and unsent, sending is possible
        /// and none is in flight.
        let quickSend: QuickSend?
        /// "No enviar a memoria": everything but an already omitted session.
        let canSkip: Bool
    }

    // MARK: ⋯

    struct OverflowItem: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case openFolder
            case openTranscript
            /// `minuta.md` outside the app, until the Minuta tab shows it.
            case openMinutes
            case applyGlossary
            /// A manual `minuta.<id>.md`, opened outside the app.
            case openManualMinutes(id: String)
            /// Removes `calendar_event` from meta.json (only when linked).
            case unlinkCalendar
            /// "Mover a la papelera…": opens the confirmation sheet.
            case moveToTrash
        }

        let kind: Kind
        let title: String
        let isEnabled: Bool
    }

    let regenerate: Regenerate
    /// nil = no memory button (integration off, or no transcript).
    let memory: Memory?
    let overflow: [OverflowItem]

    static func build(_ input: Input) -> DetailActions {
        DetailActions(
            regenerate: regenerate(input), memory: memory(input), overflow: overflow(input)
        )
    }

    // MARK: - Pieces

    private static func regenerate(_ input: Input) -> Regenerate {
        let regenerateWith: TemplateChoices? = input.hasMinutes && input.hasTranscript
            ? choices(input.templates, reason: input.minutesUnavailableReason) : nil

        let generateWith: TemplateChoices
        if !input.hasTranscript {
            generateWith = .unavailable(Textos.Sesiones.sinTranscripcion)
        } else {
            generateWith = choices(input.templates, reason: input.minutesUnavailableReason)
        }

        // Only for minutes still owed with a transcript to work from: the
        // automatic request owns the file and the hook, so the user retries
        // it instead of generating a competing one.
        let retry = input.hasTranscript && input.minutesOwed
            ? Retry(isEnabled: input.minutesUnavailableReason == nil, tooltip: input.minutesUnavailableReason) : nil
        return Regenerate(retry: retry, regenerateWith: regenerateWith, generateWith: generateWith)
    }

    /// The reason first, then "no templates", else the templates.
    private static func choices(_ templates: [MinutesTemplate], reason: String?) -> TemplateChoices {
        if let reason { return .unavailable(reason) }
        if templates.isEmpty { return .unavailable(Textos.Sesiones.sinPlantillas) }
        return .choices(templates.map {
            TemplateChoice(id: $0.id, title: $0.nombre, tooltip: $0.descripcion.isEmpty ? nil : $0.descripcion)
        })
    }

    private static func memory(_ input: Input) -> Memory? {
        guard let status = input.memory else { return nil }
        let action = status.action
        var banks: [BankChoice]?
        if action.choosesBank,
           let menu = HindsightBankMenu.build(defaultBank: input.defaultBank, otherBanks: input.otherBanks) {
            banks = menu.entries.map { BankChoice(title: $0.title, bank: $0.bank, isDefault: $0.isDefault) }
        }
        let isEnabled = !(action.choosesBank && banks == nil) && !input.memoryInFlight
        let sendable = status == .notSent || status == .short
        return Memory(
            status: status, action: action, banks: banks,
            isEnabled: isEnabled,
            quickSend: sendable && isEnabled ? banks?.first.map { QuickSend(action: action, bank: $0.bank) } : nil,
            canSkip: status != .omitted
        )
    }

    private static func overflow(_ input: Input) -> [OverflowItem] {
        var items = [
            OverflowItem(kind: .openFolder, title: Textos.Principal.mostrarCarpeta, isEnabled: true),
            OverflowItem(kind: .openTranscript, title: Textos.Sesiones.abrirTranscripcion, isEnabled: input.hasTranscriptMD),
            OverflowItem(kind: .openMinutes, title: Textos.Sesiones.abrirMinuta, isEnabled: input.hasMinutes),
            OverflowItem(kind: .applyGlossary, title: Textos.Sesiones.aplicarGlosario, isEnabled: input.hasTranscript),
        ]
        let names = Dictionary(input.templates.map { ($0.id, $0.nombre) }, uniquingKeysWith: { first, _ in first })
        for id in input.manualMinutes {
            items.append(OverflowItem(
                kind: .openManualMinutes(id: id), title: Textos.Sesiones.abrirMinuta(names[id] ?? id), isEnabled: true
            ))
        }
        if input.hasCalendarEvent {
            items.append(OverflowItem(kind: .unlinkCalendar, title: Textos.Sesiones.quitarEventoCalendario, isEnabled: true))
        }
        // Last and always enabled: a session that is recording or being
        // processed is explained by the confirmation sheet, not hidden here.
        items.append(OverflowItem(kind: .moveToTrash, title: Textos.Papelera.mover, isEnabled: true))
        return items
    }
}
