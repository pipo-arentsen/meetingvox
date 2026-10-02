import AppKit
import SwiftUI

/// The calendar toggle with its state line, the Privacy › Calendars link and
/// the explanatory note. Shared by Ajustes › Reuniones and the onboarding
/// "Listo" step so both say the same thing. Pure view over
/// `CalendarSettingsModel`: no EventKit, no config, no disk.
struct CalendarSettingsRow: View {
    let model: CalendarSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(
                Textos.Calendario.activar,
                isOn: Binding(get: { model.enabled }, set: { model.toggle($0) })
            )
            .disabled(model.isInvalid)
            Text(Textos.Calendario.nota)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let text = model.statusText {
                HStack(spacing: 8) {
                    if model.access == .requesting { ProgressView().controlSize(.small) }
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(model.showsPrivacyLink ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.showsPrivacyLink {
                Button(Textos.Calendario.abrirPrivacidad) { model.openPrivacySettings() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .task { await model.refresh() }
        // A grant made in System Settings shows on coming back, no re-toggle.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }
}

/// The "Calendario" group of Ajustes › Reuniones.
struct CalendarSettingsSection: View {
    let model: CalendarSettingsModel

    var body: some View {
        Section {
            CalendarSettingsRow(model: model)
        } header: {
            Text(Textos.Calendario.seccion).font(.title3).bold()
        }
    }
}
