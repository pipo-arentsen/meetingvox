import AppKit
import Foundation
import Observation

/// State behind the "Calendario" toggle (Ajustes › Reuniones and onboarding
/// "Listo"). The only place that raises the one calendar permission prompt,
/// and only from the user turning the toggle on while macOS has never been
/// asked: never at launch, never from a recording, never twice. Turning it
/// off writes `calendar.enabled = false` and nothing else: the OS permission
/// is not revoked (the app cannot) and stored `calendar_event` links stay.
///
/// Writes `calendar.enabled` BEFORE asking, so a later grant made in System
/// Settings works without re-toggling; a denied answer leaves the toggle on
/// and inert. The model never touches EventKit itself: everything goes
/// through the injected `CalendarSource`.
@MainActor
@Observable
final class CalendarSettingsModel {
    /// `calendar.enabled` as on disk.
    private(set) var enabled = false
    /// The last status the source reported (never prompts to read).
    private(set) var system: CalendarSystemStatus = .notDetermined
    /// The one system prompt is open.
    private(set) var requesting = false
    /// `calendar` on disk has an unexpected shape: the toggle is read-only
    /// until the file is fixed by hand.
    private(set) var isInvalid = false
    private(set) var configError: String?

    var access: CalendarAccess { .derive(enabled: enabled, system: system, requesting: requesting) }

    /// The state sentence under the toggle; nil when there is nothing to say.
    var statusText: String? {
        switch access {
        case .off: nil
        case .notDetermined: Textos.Calendario.sinResponder
        case .requesting: Textos.Calendario.solicitando
        case .authorized: Textos.Calendario.autorizado
        case .denied: Textos.Calendario.denegado
        case .restricted: Textos.Calendario.restringido
        case .unavailable: Textos.Calendario.noDisponible
        }
    }

    /// "Abrir Privacidad › Calendarios": only where macOS blocks the access.
    var showsPrivacyLink: Bool { access == .denied || access == .restricted }

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let source: any CalendarSource
    @ObservationIgnored private let notifications: NotificationCenter
    @ObservationIgnored private let openURL: (URL) -> Bool

    /// No default `configURL`: this file is scanned by `SnapshotHomeGuardTests`
    /// (no real-home access in it), so the app passes the real path explicitly.
    init(
        configURL: URL, source: any CalendarSource, notifications: NotificationCenter = .default,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        self.configURL = configURL
        self.source = source
        self.notifications = notifications
        self.openURL = openURL
        loadConfig()
    }

    // MARK: - Loading

    /// Re-reads the config and the system status. Reads only: it never
    /// requests access, so a window opening cannot raise a prompt.
    func refresh() async {
        loadConfig()
        system = await source.status()
    }

    private func loadConfig() {
        let raw: [String: Any]
        do {
            raw = try ConfigStore.loadRaw(at: configURL)
            configError = nil
        } catch {
            raw = [:]
            FileHandle.standardError.write(Data("settings: config read failed: \(error)\n".utf8))
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
        }
        let values = ConfigValues(raw: raw)
        enabled = values.calendarEnabled
        isInvalid = values.calendarFormatError != nil
        if let key = values.calendarFormatError {
            let error = ConfigStore.StoreError.invalidValue(configURL, key: key)
            configError = Textos.Ajustes.errorLeer(error.localizedDescription)
        }
    }

    // MARK: - The toggle

    /// The toggle's action. On: save the key, then ask exactly once if macOS
    /// has never been asked. Off: save the key, nothing else.
    func setEnabled(_ on: Bool) async {
        guard !isInvalid, write(on) else { return }
        guard on else { return }
        system = await source.status()
        guard !requesting, CalendarAccess.toggleOn(system: system) == .request else { return }
        requesting = true
        system = await source.requestFullAccess()
        requesting = false
    }

    /// `Binding` glue for SwiftUI's `Toggle`.
    func toggle(_ on: Bool) { Task { await setEnabled(on) } }

    /// Opens Privacy › Calendars (the Privacy root when that anchor is not
    /// available on this macOS).
    func openPrivacySettings() {
        SystemSettingsLink.openCalendars(using: openURL)
    }

    // MARK: - Persistence

    private func write(_ value: Bool) -> Bool {
        do {
            _ = try ConfigStore.update(at: configURL) { ConfigStore.set(value, at: ["calendar", "enabled"], in: &$0) }
            enabled = value
            configError = nil
            notifications.post(name: .meetingVoxConfigDidChange, object: nil)
            return true
        } catch {
            FileHandle.standardError.write(Data("settings: config write failed: \(error)\n".utf8))
            loadConfig()
            if configError == nil { configError = Textos.Ajustes.errorGuardar(error.localizedDescription) }
            return false
        }
    }
}
